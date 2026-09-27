param([Alias('ProfilesDir')][string]$RouterBuildCliProfilesDir, [Alias('OutPath')][string]$RouterBuildCliOutPath, [Alias('Now')][datetime]$RouterBuildCliNow = (Get-Date), [Alias('Json')][switch]$RouterBuildCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot '../resolve-codex-model.ps1')

$script:RouterNumericMax = 1000000000000.0
function Test-RouterFiniteNumber {
    param([object]$Value)
    try {
        if ($Value -isnot [valuetype] -or $Value -is [bool]) { return $false }
        $number = [double]$Value
        return ([double]::IsFinite($number) -and $number -ge 0 -and $number -le $script:RouterNumericMax)
    } catch { return $false }
}

function Get-RouterEvidenceUrl {
    param([string]$Url)
    $uri = $null
    if (-not [uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https')) { return '' }
    $hostName = $uri.Host.TrimEnd('.')
    if (-not $hostName) { return '' }
    $port = if ($uri.IsDefaultPort) { '' } else { ':' + $uri.Port }
    return ($uri.Scheme + '://' + $hostName + $port + $uri.AbsolutePath).TrimEnd('/').ToLowerInvariant()
}

function Get-RouterEvidenceKey {
    param([string]$Url)
    return ((Get-RouterEvidenceUrl -Url $Url) -replace '^https?://','')
}

function Test-RouterIndependentCitation {
    param([object]$Citation, [string[]]$VendorDomains)
    if ($null -eq $Citation -or -not $Citation.PSObject.Properties['url'] -or -not $Citation.PSObject.Properties['independent'] -or $Citation.independent -ne $true) { return $false }
    $url = Get-RouterEvidenceUrl -Url ([string]$Citation.url)
    if (-not $url) { return $false }
    $hostName = ([uri]$url).Host
    foreach ($domain in $VendorDomains) { if ($hostName -eq $domain -or $hostName.EndsWith('.' + $domain,[StringComparison]::OrdinalIgnoreCase)) { return $false } }
    return $true
}

function Test-RouterCitation {
    param([object]$Citation)
    if ($Citation -isnot [pscustomobject]) { return $false }
    foreach ($key in @('source','independent','note','quote')) { if (-not $Citation.PSObject.Properties[$key]) { return $false } }
    $urlValid = (-not $Citation.PSObject.Properties['url'] -or -not $Citation.url -or [bool](Get-RouterEvidenceUrl -Url ([string]$Citation.url)))
    return ($Citation.source -is [string] -and $Citation.source -and $urlValid -and $Citation.independent -is [bool] -and
        $Citation.note -is [string] -and $Citation.quote -is [string] -and $Citation.quote.Length -gt 0 -and $Citation.quote.Length -le 500)
}

function Test-RouterNumberSource {
    param([object]$Value)
    if ($null -eq $Value) { return $true }
    if ($Value -isnot [pscustomobject] -or -not $Value.PSObject.Properties['value'] -or -not $Value.PSObject.Properties['source']) { return $false }
    return ((Test-RouterFiniteNumber $Value.value) -and (Test-RouterCitation $Value.source))
}

function Test-RouterProfile {
    param([object]$Profile)
    if ($Profile -isnot [pscustomobject]) { return $false }
    foreach ($key in @('schema_version','model','lane','researched_at','frontier','voice_policy_check','categories')) { if (-not $Profile.PSObject.Properties[$key]) { return $false } }
    $date = [datetimeoffset]::MinValue
    if ($Profile.schema_version -isnot [long] -or $Profile.schema_version -ne 1 -or
        $Profile.model -isnot [string] -or $Profile.model -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$' -or
        $Profile.lane -cnotin @('codex','claude') -or $Profile.frontier -isnot [bool] -or
        $Profile.voice_policy_check -cnotin @('passed','failed','unknown') -or
        ($Profile.researched_at -isnot [string] -and $Profile.researched_at -isnot [datetime]) -or -not [datetimeoffset]::TryParse([string]$Profile.researched_at,[ref]$date) -or
        $Profile.categories -isnot [pscustomobject]) { return $false }
    $expected = if ($Profile.lane -eq 'codex') { @(Get-RouterCategories) } else { @(Get-RouterCategories | Where-Object { $_ -ne 'image-generation' }) }
    foreach ($category in $expected) {
        $field = $Profile.categories.PSObject.Properties[$category]
        if (-not $field -or $field.Value -isnot [pscustomobject]) { return $false }
        $row = $field.Value
        foreach ($key in @('grade','citations','benchmark_scores','price_per_token','tokens_per_task','output_speed')) { if (-not $row.PSObject.Properties[$key]) { return $false } }
        if ($row.grade -cnotin @('strong','capable','weak','unknown') -or $row.citations -isnot [array] -or $row.benchmark_scores -isnot [array]) { return $false }
        foreach ($citation in $row.citations) { if (-not (Test-RouterCitation $citation)) { return $false } }
        foreach ($score in $row.benchmark_scores) {
            if ($score -isnot [pscustomobject] -or -not $score.PSObject.Properties['name'] -or $score.name -isnot [string] -or -not $score.name -or -not (Test-RouterNumberSource $score)) { return $false }
        }
        foreach ($key in @('price_per_token','tokens_per_task','output_speed')) { if (-not (Test-RouterNumberSource $row.$key)) { return $false } }
    }
    return $true
}

function Get-RouterProfileNumericIssues {
    param([object]$Profile, [string[]]$VendorDomains)
    $issues = [System.Collections.Generic.List[string]]::new()
    foreach ($categoryProperty in $Profile.categories.PSObject.Properties) {
        $evidence = $categoryProperty.Value
        if ($null -ne $evidence.price_per_token -and $null -ne $evidence.tokens_per_task) {
            $burn = [double]$evidence.price_per_token.value * [double]$evidence.tokens_per_task.value
            if (-not (Test-RouterFiniteNumber $burn)) { $issues.Add('invalid-burn') }
        }
        if ($null -ne $evidence.output_speed -and [double]$evidence.output_speed.value -gt 0 -and $null -ne $evidence.tokens_per_task) {
            $seconds = [double]$evidence.tokens_per_task.value / [double]$evidence.output_speed.value
            if (-not (Test-RouterFiniteNumber $seconds)) { $issues.Add('invalid-seconds') }
        }
        $score = 0.0
        foreach ($benchmark in $evidence.benchmark_scores) {
            if (Test-RouterIndependentCitation $benchmark.source $VendorDomains) {
                $score += [double]$benchmark.value
                if (-not (Test-RouterFiniteNumber $score)) { $issues.Add('invalid-benchmark'); break }
            }
        }
    }
    return @($issues.ToArray() | Select-Object -Unique)
}

function Build-RouterTable {
    param([Parameter(Mandatory)][string]$ProfilesDir, [Parameter(Mandatory)][string]$OutPath, [datetime]$Now = (Get-Date))
    $alerts = [System.Collections.Generic.List[string]]::new()
    $base = Read-RouterTable -TablePath $OutPath
    $table = $base.table | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
    $frontierConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json
    $table.source = 'research'
    $table.generated_at = $Now.ToString('yyyy-MM-dd')
    $profiles = @{}
    if (Test-Path -LiteralPath $ProfilesDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $ProfilesDir -File -Filter '*.json' | Sort-Object Name)) {
            try {
                $profile = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 40
                if (-not (Test-RouterProfile $profile) -or $file.BaseName -cne $profile.model) { throw 'invalid profile' }
                $numericIssues = @(Get-RouterProfileNumericIssues -Profile $profile -VendorDomains $frontierConfig.vendor_domains)
                if ($numericIssues.Count) { throw ($numericIssues -join ',') }
                $profiles[[string]$profile.model] = $profile
                if (($Now - [datetime]$profile.researched_at).TotalDays -gt 90) { $alerts.Add("stale-profile:$($profile.model)") }
            } catch { $alerts.Add("research-profile-invalid:$($file.BaseName)"); continue }
        }
    }
    $catalog = $null
    try { $catalog = Get-CodexModelCatalog } catch { }
    # Long-form-writing fallback never comes from research ranking: the highest-versioned non-frontier claude-opus-* model
    # among the table's Claude candidates, Claude profiles, and the known-models registry.
    $claudeIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($categoryProperty in $table.categories.PSObject.Properties) { if ($categoryProperty.Value.PSObject.Properties['claude']) { foreach ($old in @($categoryProperty.Value.claude.candidates)) { [void]$claudeIds.Add([string]$old.model) } } }
    foreach ($profile in $profiles.Values) { if ($profile.lane -eq 'claude') { [void]$claudeIds.Add([string]$profile.model) } }
    $known = @()
    try { $known = @(Read-RouterJsonArray -Path (Join-Path (Split-Path -Parent $OutPath) 'known-models.json')) } catch { }
    foreach ($item in $known) { if ($item -is [pscustomobject] -and $item.PSObject.Properties['id'] -and -not ($item.PSObject.Properties['status'] -and $item.status -eq 'missing')) { [void]$claudeIds.Add([string]$item.id) } }
    $topWritingClaude = $null; $topWritingVersion = $null
    foreach ($id in @($claudeIds | Sort-Object)) {
        if ($id -cnotmatch '^claude-opus-\d{1,9}(-\d{1,9})*$') { continue }
        if (@($frontierConfig.claude_patterns | Where-Object { $id -clike $_ }).Count) { continue }
        $version = @($id.Substring(12).Split('-') | ForEach-Object { [long]$_ })
        $better = $null -eq $topWritingVersion
        for ($i = 0; -not $better -and $i -lt [Math]::Max($version.Count,$topWritingVersion.Count); $i++) {
            $a = if ($i -lt $version.Count) { $version[$i] } else { -1 }
            $b = if ($i -lt $topWritingVersion.Count) { $topWritingVersion[$i] } else { -1 }
            if ($a -gt $b) { $better = $true } elseif ($a -lt $b) { break }
        }
        if ($better) { $topWritingClaude = $id; $topWritingVersion = $version }
    }
    foreach ($categoryName in @(Get-RouterCategories)) {
        if ($categoryName -eq 'long-form-writing' -and -not $topWritingClaude) { $topWritingClaude = [string]$table.categories.'complex-coding'.claude.fallback }
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
                $citations = [System.Collections.Generic.List[object]]::new()
                $seenUrls = @{}
                foreach ($citation in $evidence.citations) {
                    $citationUrl = if ($citation.PSObject.Properties['url']) { [string]$citation.url } else { '' }
                    $url = Get-RouterEvidenceUrl -Url $citationUrl
                    $key = Get-RouterEvidenceKey -Url $citationUrl
                    if (-not $url -or $seenUrls.ContainsKey($key)) { continue }
                    $seenUrls[$key] = $true
                    $citations.Add([pscustomobject]@{ source = [string]$citation.source; url = $url; independent = (Test-RouterIndependentCitation $citation $frontierConfig.vendor_domains); note = ''; quote = [string]$citation.quote })
                }
                $candidate.citations = @($citations.ToArray())
                $candidate.frontier = $false
                if ($laneName -eq 'claude') { foreach ($pattern in $frontierConfig.claude_patterns) { if ($profile.model -clike $pattern) { $candidate.frontier = $true } } }
                if ($laneName -eq 'codex' -and $frontierConfig.codex_models -ccontains $profile.model) { $candidate.frontier = $true }
                if ($laneName -eq 'codex' -and $null -ne $catalog) {
                    $catalogRow = @($catalog.models | Where-Object { $_.PSObject.Properties['slug'] -and $_.slug -eq $profile.model } | Select-Object -First 1)
                    if ($catalogRow.Count -and $catalogRow[0].PSObject.Properties['description'] -and [string]$catalogRow[0].description -match 'frontier') { $candidate.frontier = $true }
                }
                # Numeric overflow for this profile's category evidence was already screened out in the profile-loading
                # loop above (Get-RouterProfileNumericIssues); an invalid profile never reaches this point, so these
                # computations are guarded defensively rather than aborting the whole rebuild.
                $candidate.est_burn = $null; $candidate.est_seconds = $null
                if ($null -ne $evidence.price_per_token -and $null -ne $evidence.tokens_per_task) {
                    $burn = [double]$evidence.price_per_token.value * [double]$evidence.tokens_per_task.value
                    if (Test-RouterFiniteNumber $burn) { $candidate.est_burn = $burn }
                }
                if ($null -ne $evidence.output_speed -and [double]$evidence.output_speed.value -gt 0 -and $null -ne $evidence.tokens_per_task) {
                    $seconds = [double]$evidence.tokens_per_task.value / [double]$evidence.output_speed.value
                    if (Test-RouterFiniteNumber $seconds) { $candidate.est_seconds = $seconds }
                }
            }
            foreach ($candidate in $rows) {
                $candidate.frontier = $false
                if ($laneName -eq 'claude') { foreach ($pattern in $frontierConfig.claude_patterns) { if ($candidate.model -clike $pattern) { $candidate.frontier = $true } } }
                if ($laneName -eq 'codex' -and $frontierConfig.codex_models -ccontains $candidate.model) { $candidate.frontier = $true }
                if ($laneName -eq 'codex' -and $null -ne $catalog) {
                    $catalogRow = @($catalog.models | Where-Object { $_.PSObject.Properties['slug'] -and $_.slug -eq $candidate.model } | Select-Object -First 1)
                    if ($catalogRow.Count -and $catalogRow[0].PSObject.Properties['description'] -and [string]$catalogRow[0].description -match 'frontier') { $candidate.frontier = $true }
                }
            }
            if ($categoryName -eq 'long-form-writing') {
                if ($laneName -eq 'claude' -and @($rows | Where-Object { $_.model -eq $topWritingClaude }).Count -eq 0) {
                    $rows.Add([pscustomobject]@{ model = $topWritingClaude; frontier = $false; strength_rank = [long]($rows.Count + 1); grade = 'unknown'; citations = @(); est_burn = $null; est_seconds = $null; pass_rate = $null; pass_samples = [long]0 })
                }
                foreach ($candidate in $rows) {
                    $profile = if ($profiles.ContainsKey([string]$candidate.model)) { $profiles[[string]$candidate.model] } else { $null }
                    $exempt = $laneName -eq 'claude' -and ($candidate.frontier -or $candidate.model -eq $topWritingClaude)
                    if (-not $exempt -and ($null -eq $profile -or $profile.voice_policy_check -cne 'passed')) { $candidate.grade = 'unknown'; $candidate.citations = @() }
                }
            }
            $graded = [System.Collections.Generic.List[object]]::new()
            foreach ($candidate in $rows) {
                $profile = if ($profiles.ContainsKey([string]$candidate.model)) { $profiles[[string]$candidate.model] } else { $null }
                $evidence = if ($null -ne $profile) { $profile.categories.$categoryName } else { $null }
                $sources = @($candidate.citations | Where-Object independent | ForEach-Object { Get-RouterEvidenceKey ([string]$_.url) } | Where-Object { $_ } | Sort-Object -Unique)
                $count = [Math]::Min(5,$sources.Count)
                $score = 0.0
                if ($null -ne $evidence) {
                    foreach ($benchmark in $evidence.benchmark_scores) {
                        if (Test-RouterIndependentCitation $benchmark.source $frontierConfig.vendor_domains) {
                            $candidateScore = $score + [double]$benchmark.value
                            if (Test-RouterFiniteNumber $candidateScore) { $score = $candidateScore }
                        }
                    }
                }
                $gradeOrder = if ($categoryName -eq 'long-form-writing' -and $laneName -eq 'claude' -and $candidate.model -eq $topWritingClaude) { -1 } elseif ($candidate.grade -eq 'strong') { 0 } elseif ($candidate.grade -eq 'capable') { 1 } elseif ($candidate.grade -eq 'weak') { 2 } else { 3 }
                $graded.Add([pscustomobject]@{ row = $candidate; grade = $gradeOrder; count = $count; score = [double]$score; old = [long]$candidate.strength_rank })
            }
            $ordered = @($graded.ToArray() | Sort-Object grade, @{ Expression = 'count'; Descending = $true }, @{ Expression = 'score'; Descending = $true }, old, @{ Expression = { $_.row.model } })
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
    try {
        $serialized = $json | ConvertFrom-Json -Depth 40
        $serializedErrors = @(Test-RouterTable -Table $serialized)
        if ($serializedErrors.Count) { throw ($serializedErrors -join '; ') }
    } catch { $alerts.Add("router-table-build-invalid:$($_.Exception.Message)"); return [pscustomobject]@{ written = $false; alerts = @($alerts.ToArray()); table = $null } }
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
