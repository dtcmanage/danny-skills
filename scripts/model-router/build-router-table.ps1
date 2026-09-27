param([Alias('ProfilesDir')][string]$RouterBuildCliProfilesDir, [Alias('OutPath')][string]$RouterBuildCliOutPath, [Alias('Now')][datetime]$RouterBuildCliNow = (Get-Date), [Alias('Json')][switch]$RouterBuildCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot '../resolve-codex-model.ps1')

function Test-RouterCitation {
    param([object]$Citation)
    if ($Citation -isnot [pscustomobject]) { return $false }
    foreach ($key in @('source','url','independent','note','quote')) { if (-not $Citation.PSObject.Properties[$key]) { return $false } }
    return ($Citation.source -is [string] -and $Citation.source -and $Citation.url -is [string] -and
        [uri]::IsWellFormedUriString($Citation.url,[UriKind]::Absolute) -and $Citation.independent -is [bool] -and
        $Citation.note -is [string] -and $Citation.quote -is [string] -and $Citation.quote.Length -gt 0 -and $Citation.quote.Length -le 500)
}

function Test-RouterNumberSource {
    param([object]$Value)
    if ($null -eq $Value) { return $true }
    if ($Value -isnot [pscustomobject] -or -not $Value.PSObject.Properties['value'] -or -not $Value.PSObject.Properties['source']) { return $false }
    try { return ($Value.value -is [valuetype] -and $Value.value -isnot [bool] -and [double]::IsFinite([double]$Value.value) -and [double]$Value.value -ge 0 -and (Test-RouterCitation $Value.source)) } catch { return $false }
}

function Test-RouterProfile {
    param([object]$Profile)
    if ($Profile -isnot [pscustomobject]) { return $false }
    foreach ($key in @('schema_version','model','lane','researched_at','frontier','voice_policy_check','categories')) { if (-not $Profile.PSObject.Properties[$key]) { return $false } }
    $date = [datetimeoffset]::MinValue
    if ($Profile.schema_version -isnot [long] -or $Profile.schema_version -ne 1 -or
        $Profile.model -isnot [string] -or $Profile.model -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$' -or
        $Profile.lane -notin @('codex','claude') -or $Profile.frontier -isnot [bool] -or
        $Profile.voice_policy_check -notin @('passed','failed','unknown') -or
        ($Profile.researched_at -isnot [string] -and $Profile.researched_at -isnot [datetime]) -or -not [datetimeoffset]::TryParse([string]$Profile.researched_at,[ref]$date) -or
        $Profile.categories -isnot [pscustomobject]) { return $false }
    $expected = if ($Profile.lane -eq 'codex') { @(Get-RouterCategories) } else { @(Get-RouterCategories | Where-Object { $_ -ne 'image-generation' }) }
    foreach ($category in $expected) {
        $field = $Profile.categories.PSObject.Properties[$category]
        if (-not $field -or $field.Value -isnot [pscustomobject]) { return $false }
        $row = $field.Value
        foreach ($key in @('grade','citations','benchmark_scores','price_per_token','tokens_per_task','output_speed')) { if (-not $row.PSObject.Properties[$key]) { return $false } }
        if ($row.grade -notin @('strong','capable','weak','unknown') -or $row.citations -isnot [array] -or $row.benchmark_scores -isnot [array]) { return $false }
        foreach ($citation in $row.citations) { if (-not (Test-RouterCitation $citation)) { return $false } }
        foreach ($score in $row.benchmark_scores) {
            if ($score -isnot [pscustomobject] -or -not $score.PSObject.Properties['name'] -or $score.name -isnot [string] -or -not $score.name -or -not (Test-RouterNumberSource $score)) { return $false }
        }
        foreach ($key in @('price_per_token','tokens_per_task','output_speed')) { if (-not (Test-RouterNumberSource $row.$key)) { return $false } }
    }
    return $true
}

function Build-RouterTable {
    param([Parameter(Mandatory)][string]$ProfilesDir, [Parameter(Mandatory)][string]$OutPath, [datetime]$Now = (Get-Date))
    $alerts = [System.Collections.Generic.List[string]]::new()
    $base = Read-RouterTable -TablePath $OutPath
    $table = $base.table | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
    $seed = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/seed-table.json') -Raw | ConvertFrom-Json -Depth 40
    $topWritingClaude = @($seed.categories.'long-form-writing'.claude.candidates | Where-Object { -not $_.frontier } | Sort-Object strength_rank | Select-Object -First 1)[0].model
    $table.source = 'research'
    $table.generated_at = $Now.ToString('yyyy-MM-dd')
    $profiles = @{}
    if (Test-Path -LiteralPath $ProfilesDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $ProfilesDir -File -Filter '*.json' | Sort-Object Name)) {
            try {
                $profile = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 40
                if (-not (Test-RouterProfile $profile) -or $file.BaseName -cne $profile.model) { throw 'invalid profile' }
                $profiles[[string]$profile.model] = $profile
                if (($Now - [datetime]$profile.researched_at).TotalDays -gt 90) { $alerts.Add("stale-profile:$($profile.model)") }
            } catch { $alerts.Add("invalid-profile:$($file.BaseName)") }
        }
    }
    $catalog = $null
    try { $catalog = Get-CodexModelCatalog } catch { }
    foreach ($categoryName in @(Get-RouterCategories)) {
        $category = $table.categories.$categoryName
        $lanes = if ($categoryName -eq 'image-generation') { @('codex') } else { @('codex','claude') }
        foreach ($laneName in $lanes) {
            $lane = $category.$laneName
            $oldRows = @($lane.candidates)
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($old in $oldRows) { $rows.Add($old) }
            foreach ($profile in @($profiles.Values | Where-Object { $_.lane -eq $laneName } | Sort-Object model)) {
                $row = @($rows | Where-Object { $_.model -eq $profile.model } | Select-Object -First 1)
                if ($categoryName -eq 'image-generation' -and $row.Count -eq 0 -and
                    $profile.categories.'image-generation'.grade -eq 'unknown' -and
                    @($profile.categories.'image-generation'.citations).Count -eq 0) { continue }
                if ($row.Count -eq 0) {
                    $new = [pscustomobject]@{ model = $profile.model; frontier = $false; strength_rank = [long]($rows.Count + 1); grade = 'unknown'; citations = @(); est_burn = $null; est_seconds = $null; pass_rate = $null; pass_samples = [long]0 }
                    $rows.Add($new); $row = @($new)
                }
                $candidate = $row[0]
                $evidence = $profile.categories.$categoryName
                $candidate.grade = [string]$evidence.grade
                $candidate.citations = @($evidence.citations | ForEach-Object { [pscustomobject]@{ source = [string]$_.source; url = [string]$_.url; independent = [bool]$_.independent; note = ''; quote = [string]$_.quote } })
                $candidate.frontier = [bool]$profile.frontier
                if ($laneName -eq 'codex' -and $null -ne $catalog) {
                    $catalogRow = @($catalog.models | Where-Object { $_.PSObject.Properties['slug'] -and $_.slug -eq $profile.model } | Select-Object -First 1)
                    if ($catalogRow.Count -and $catalogRow[0].PSObject.Properties['description'] -and [string]$catalogRow[0].description -match 'frontier') { $candidate.frontier = $true }
                }
                if ($null -ne $evidence.price_per_token -and $null -ne $evidence.tokens_per_task) { $candidate.est_burn = [double]$evidence.price_per_token.value * [double]$evidence.tokens_per_task.value }
                if ($null -ne $evidence.output_speed -and [double]$evidence.output_speed.value -gt 0 -and $null -ne $evidence.tokens_per_task) { $candidate.est_seconds = [double]$evidence.tokens_per_task.value / [double]$evidence.output_speed.value }
                if ($categoryName -eq 'long-form-writing' -and -not $candidate.frontier -and $profile.voice_policy_check -ne 'passed') {
                    # Restrict below after all profiles are ranked, retaining the top Claude candidate.
                }
            }
            $graded = foreach ($candidate in $rows) {
                $profile = if ($profiles.ContainsKey([string]$candidate.model)) { $profiles[[string]$candidate.model] } else { $null }
                $evidence = if ($null -ne $profile) { $profile.categories.$categoryName } else { $null }
                $count = if ($null -ne $evidence) { @($evidence.citations | Where-Object independent).Count } else { @($candidate.citations | Where-Object independent).Count }
                $score = 0.0
                if ($null -ne $evidence) { foreach ($benchmark in $evidence.benchmark_scores) { $score += [double]$benchmark.value } }
                [pscustomobject]@{ row = $candidate; grade = $(if ($candidate.grade -eq 'strong') { 0 } elseif ($candidate.grade -eq 'capable') { 1 } elseif ($candidate.grade -eq 'weak') { 2 } else { 3 }); count = $count; score = [double]$score; old = [long]$candidate.strength_rank }
            }
            $ordered = @($graded | Sort-Object grade, @{ Expression = 'count'; Descending = $true }, @{ Expression = 'score'; Descending = $true }, old, @{ Expression = { $_.row.model } })
            if ($categoryName -eq 'long-form-writing') {
                foreach ($item in $ordered) {
                    $profile = if ($profiles.ContainsKey([string]$item.row.model)) { $profiles[[string]$item.row.model] } else { $null }
                    if (-not $item.row.frontier -and ($laneName -ne 'claude' -or $item.row.model -ne $topWritingClaude) -and ($null -eq $profile -or $profile.voice_policy_check -ne 'passed')) { $item.row.grade = 'unknown' }
                }
            }
            $rank = 0
            foreach ($item in $ordered) { $rank++; $item.row.strength_rank = [long]$rank }
            $lane.candidates = @($ordered | ForEach-Object { $_.row })
            $nonfrontier = @($ordered | Where-Object { -not $_.row.frontier } | Select-Object -First 1)
            if ($nonfrontier.Count) { $lane.fallback = [string]$nonfrontier[0].row.model }
            if ($categoryName -eq 'image-generation') { $lane | Add-Member -NotePropertyName advisory -NotePropertyValue $true -Force }
        }
    }
    $errors = @(Test-RouterTable -Table $table)
    if ($errors.Count) { $alerts.Add("router-table-build-invalid:$($errors -join '; ')"); return [pscustomobject]@{ written = $false; alerts = @($alerts.ToArray()); table = $null } }
    $json = ConvertTo-Json -InputObject $table -Depth 40
    $directory = Split-Path -Parent $OutPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temp = Join-Path $directory ('.router-table.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$OutPath,$true) }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    return [pscustomobject]@{ written = $true; alerts = @($alerts.ToArray()); table = $table }
}

if ($MyInvocation.InvocationName -ne '.') {
    $state = Get-RouterStateDir
    $profiles = if ($RouterBuildCliProfilesDir) { $RouterBuildCliProfilesDir } else { Join-Path $state 'profiles' }
    $out = if ($RouterBuildCliOutPath) { $RouterBuildCliOutPath } else { Join-Path $state 'router-table.json' }
    $result = Build-RouterTable -ProfilesDir $profiles -OutPath $out -Now $RouterBuildCliNow
    if ($RouterBuildCliJson) { $result | ConvertTo-Json -Depth 40 -Compress } else { $result }
}
