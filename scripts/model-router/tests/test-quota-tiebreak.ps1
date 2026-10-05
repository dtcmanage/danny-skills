Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$priorState = $env:DT_MODEL_ROUTER_STATE
$priorSessions = $env:DT_MODEL_ROUTER_CODEX_SESSIONS
$temp = Join-Path $env:TEMP ('quota-tie-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $temp 'sessions'
$fixture = Enter-RouterTestCodexHome
$script:passed = 0
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Output "PASS: $Name"
}
$script:guardCalls = 0
function Invoke-RestMethod { $script:guardCalls++; throw 'NETWORK GUARD' }
function Invoke-WebRequest { $script:guardCalls++; throw 'NETWORK GUARD' }
function Update-CodexModelCatalog { $script:guardCalls++; throw 'MODEL GUARD' }
function codex { $script:guardCalls++; throw 'MODEL GUARD' }
function claude { $script:guardCalls++; throw 'MODEL GUARD' }
$script:RouterClaudeCredentialProvider = { [pscustomobject]@{status='missing'} }
$script:RouterClaudeUsageFetcher = { $script:guardCalls++; throw 'NETWORK GUARD' }
$script:RouterDiagnosisHttp = { $script:guardCalls++; throw 'NETWORK GUARD' }
$script:RouterDiagnosisDns = { $script:guardCalls++; throw 'NETWORK GUARD' }
function Save-Usage([double]$Codex, [double]$Claude, [double]$Age = 0) {
    $observed = [datetimeoffset]::UtcNow.AddHours(-$Age).ToString('o')
    $reset = [datetimeoffset]::UtcNow.AddDays(1)
    Write-RouterJsonAtomic (Join-Path $temp 'claude-usage.json') @{used_percent=$Claude;resets_at_utc=$reset.ToString('o');observed_at_utc=$observed;source='oauth-usage';credential_locator_identity=(Get-RouterClaudeCredentialIdentity)}
    $dir = Join-Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS '2026/10/04'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $limits = @{primary=@{window_minutes=10080;used_percent=$Codex;resets_at=$reset.ToUnixTimeSeconds()};secondary=$null}
    @{type='event_msg';timestamp=$observed;payload=@{type='token_count';rate_limits=$limits}} | ConvertTo-Json -Depth 10 -Compress | Set-Content (Join-Path $dir 'usage.jsonl')
}
function Save-Roster { Write-RouterJsonAtomic (Join-Path $temp 'roster.json') $script:roster }
try {
    $catalog = Get-CodexModelCatalog
    $script:roster = Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 20
    $roster.approved = $true; $roster.approved_at = [datetimeoffset]::UtcNow.ToString('o')
    $entry = $roster.jobs.coder
    $evidence = [pscustomobject]@{tier='standard';run_id='synthetic';bank_hash=(Get-RouterBenchEvidenceContext).task_bank_sha256;approved_at=$roster.approved_at;configurations=[pscustomobject]@{candidate=[pscustomobject]@{model=$entry.backup;effort=$entry.backup_effort};incumbent=[pscustomobject]@{model=$entry.first;effort=$entry.first_effort}}}
    Write-RouterJsonAtomic (Join-Path $temp 'bench/bank-hash.json') @{task_bank_sha256=$evidence.bank_hash;written_at=[datetimeoffset]::UtcNow.ToString('o')}
    $entry | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $evidence
    Save-Roster
    Save-Usage 70 20
    $entry.PSObject.Properties.Remove('tie_evidence'); Save-Roster
    $pick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Check ($pick.model -eq $entry.first) 'no recorded tie approval keeps first'
    $entry | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $evidence; Save-Roster
    $pick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Check ($pick.model -eq $entry.backup -and $pick.reason -match 'codex: 70%' -and $pick.reason -match 'claude: 20%') 'lower-use vendor and both readings'
    Remove-Item -LiteralPath (Join-Path $temp 'bench/bank-hash.json')
    $missingBank = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Check ($missingBank.model -eq $entry.first -and $missingBank.alerts -notcontains 'roster-tie-invalid:coder') 'absent bank skips tie quietly'
    Write-RouterJsonAtomic (Join-Path $temp 'bench/bank-hash.json') @{task_bank_sha256='changed'}
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).alerts -contains 'roster-tie-invalid:coder') 'present mismatched bank still alerts'
    Write-RouterJsonAtomic (Join-Path $temp 'bench/bank-hash.json') @{task_bank_sha256=$evidence.bank_hash}
    $usagePath = Join-Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS '2026/10/04/usage.jsonl'
    $row = Get-Content $usagePath -Raw | ConvertFrom-Json -Depth 10
    $row.payload.rate_limits.secondary = $row.payload.rate_limits.primary
    $row.payload.rate_limits.primary = [pscustomobject]@{window_minutes=300;used_percent=0;resets_at=$row.payload.rate_limits.secondary.resets_at}
    $row | ConvertTo-Json -Depth 10 -Compress | Set-Content $usagePath
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.backup) 'weekly secondary overrides short-window primary for tie'
    Save-Usage 20 70
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) 'lower-use first retained'
    foreach ($use in @(24,25)) {
        Save-Usage $use 20
        Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) "inside inclusive margin $use"
    }
    Save-Usage 70 20 6.1
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) 'stale keeps first'
    Save-Usage 70 20
    Remove-Item (Join-Path $temp 'claude-usage.json')
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) 'missing Claude keeps first'
    Save-Usage 70 20
    Remove-Item (Join-Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS '2026/10/04/usage.jsonl')
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) 'missing Codex keeps first'
    Save-Usage 70 20
    foreach ($side in @('candidate','incumbent')) {
        foreach ($field in @('model','effort')) {
            $old = $evidence.configurations.$side.$field
            $evidence.configurations.$side.$field = 'changed'; Save-Roster
            $pick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
            Check ($pick.model -eq $entry.first -and $pick.alerts -contains 'roster-tie-invalid:coder') "void on $side $field change"
            $evidence.configurations.$side.$field = $old
        }
    }
    $hash = $evidence.bank_hash; $evidence.bank_hash = 'old-bank'; Save-Roster
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).alerts -contains 'roster-tie-invalid:coder') 'void on bank change'
    $evidence.bank_hash = $hash; Save-Roster
    Check ((Resolve-RouterModel -Category routine-coding -Lane codex -Catalog $catalog).model -eq $entry.first) 'lane precedes tie'
    Check ((Resolve-RouterModel -Category routine-coding -EscalateFrom $entry.first -Catalog $catalog).model -eq $entry.first) 'escalation excludes tie'
    Write-RouterJsonAtomic (Join-Path $temp 'drift-marks.json') @(@{job='coder';model=$entry.backup})
    $pick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Check ($pick.model -eq $entry.first -and $pick.reason -match 'codex: 70%' -and $pick.reason -match 'claude: 20%' -and $pick.reason -match 'drifting') 'drift overrides quota choice with readings retained'
    Write-RouterJsonAtomic (Join-Path $temp 'drift-marks.json') @()
    Save-Usage 99 96
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).status -eq 'wait') '95 percent block precedes tie'
    Save-Usage 70 20
    Write-RouterJsonAtomic (Join-Path $temp 'vendor-blocks.json') @(@{vendor='claude';reason='vendor_incident';component='synthetic';blocked_at_utc=[datetimeoffset]::UtcNow.ToString('o')})
    $pick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Check ($pick.model -eq $entry.first -and $pick.reason -match "Selected $($entry.first): claude under a vendor incident" -and $pick.reason -notmatch 'backup selected') 'incident overrides tie and reason describes actual chosen model'
    Write-RouterJsonAtomic (Join-Path $temp 'vendor-blocks.json') @()
    $pick = Resolve-RouterModel -Category mechanical -Protected -Catalog $catalog
    Check ($pick.job -eq 'coder' -and $pick.protected -and $pick.model -eq $entry.backup) 'protected handling chooses coder before tie'
    Check ((Resolve-RouterModel -Category long-form-writing -Catalog $catalog).protected) 'writer protected handling unchanged'
    $writer = $roster.jobs.writer
    $writerEvidence = $evidence | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
    $writerEvidence.configurations.incumbent.model = $writer.first
    $writerEvidence.configurations.incumbent.effort = $writer.first_effort
    $writerEvidence.configurations.candidate.model = $writer.backup
    $writerEvidence.configurations.candidate.effort = $writer.backup_effort
    $writer | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $writerEvidence; Save-Roster
    Save-Usage 20 70
    $pick = Resolve-RouterModel -Category long-form-writing -Catalog $catalog
    Check ($pick.protected -and $pick.model -eq $writer.backup) 'protected writer uses approved quota tie'
    Save-Usage 70 20
    $pick = Resolve-RouterModel -Category routine-coding
    Check ($pick.status -eq 'ok') 'automatic local catalog resolution'
    Check ($script:guardCalls -eq 0) 'fresh local readings add no network or model calls'
    $bankPath = Join-Path $temp 'bench/bank-hash.json'
    $bankBytes = [IO.File]::ReadAllText($bankPath)
    foreach ($shape in @('absent','unreadable')) {
        if ($shape -eq 'absent') { Remove-Item $bankPath } else { Set-Content $bankPath '{' }
        $pick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
        $invalidAlert = $pick.alerts -contains 'roster-tie-invalid:coder'
        Check ($pick.model -eq $entry.first -and $invalidAlert -eq ($shape -eq 'unreadable')) "skip on $shape bank hash; alert only when present"
    }
    [IO.File]::WriteAllText($bankPath,$bankBytes)
    # A Python launch during resolve must fail this guard, even if swallowed.
    function python { $script:guardCalls++; throw 'PYTHON GUARD' }
    function python3 { $script:guardCalls++; throw 'PYTHON GUARD' }
    function py { $script:guardCalls++; throw 'PYTHON GUARD' }
    $beforeCalls = $script:guardCalls
    $hashPick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Check ($script:guardCalls -eq $beforeCalls -and $hashPick.model -eq $entry.backup -and $hashPick.alerts -notcontains 'roster-tie-invalid:coder') 'resolve reads recorded hash without starting Python'
    foreach ($use in @(25.0001,25.04,24.96)) {
        Save-Usage $use 20
        Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) "rounded inclusive margin $use"
    }
    Save-Usage 25.05 20
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.backup) 'midpoint rounds away from zero above margin'
    Save-Usage 25.06 20
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.backup) 'rounded difference above margin switches'
    Save-Usage 70 20
    $pick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Check ([regex]::Matches($pick.reason,'\d{4}-\d{2}-\d{2} \d{1,2}:\d{2}:\d{2} [AP]M ET').Count -eq 2) 'both reading times use same Eastern format'
    foreach ($defect in @('short-primary-null-secondary','short-secondary','no-window')) {
        Save-Usage 70 20
        $row = Get-Content $usagePath -Raw | ConvertFrom-Json -Depth 10
        $row.payload.rate_limits.primary.window_minutes = 300
        if ($defect -eq 'short-secondary') {
            $row.payload.rate_limits.secondary = $row.payload.rate_limits.primary
        } elseif ($defect -eq 'no-window') {
            $row.payload.rate_limits.primary.PSObject.Properties.Remove('window_minutes')
        }
        $row | ConvertTo-Json -Depth 10 -Compress | Set-Content $usagePath
        Check ($null -eq (Get-RouterCodexUsage -Weekly)) "weekly reading rejects $defect"
        Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) "weekly comparison rejects $defect"
    }
    Save-Usage 70 20
    $bad = Read-RouterJsonObject (Join-Path $temp 'claude-usage.json')
    $bad.credential_locator_identity = 'wrong-identity'
    Write-RouterJsonAtomic (Join-Path $temp 'claude-usage.json') $bad
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) 'identity mismatch keeps first'
    Save-Usage 70 20
    $bad = Read-RouterJsonObject (Join-Path $temp 'claude-usage.json')
    $bad.source = 'five-hour'
    Write-RouterJsonAtomic (Join-Path $temp 'claude-usage.json') $bad
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) 'nonweekly Claude reading keeps first'
    # Claude-first baseline refreshes normally. Tie reuses that exact refreshed cache.
    $writer.PSObject.Properties.Remove('tie_evidence'); Save-Roster
    Save-Usage 20 70 1
    $script:RouterClaudeCredentialProvider = { [pscustomobject]@{status='available';token='synthetic'} }
    $script:RouterClaudeUsageFetcher = { $script:guardCalls++; [pscustomobject]@{seven_day=[pscustomobject]@{utilization=70;resets_at=[datetimeoffset]::UtcNow.AddDays(1).ToString('o')}} }
    $beforeCalls = $script:guardCalls
    $without = Resolve-RouterModel -Category long-form-writing -Catalog $catalog
    $baselineCalls = $script:guardCalls - $beforeCalls
    Save-Usage 20 70 1
    $writer | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $writerEvidence; Save-Roster
    $beforeCalls = $script:guardCalls
    $with = Resolve-RouterModel -Category long-form-writing -Catalog $catalog
    Check ($baselineCalls -eq 1 -and $script:guardCalls - $beforeCalls -eq $baselineCalls -and $with.model -eq $writer.backup) 'tie reuses normal Claude refresh with no additional call'
    Check ($with.reason -notmatch 'stale or missing') 'tie uses newly refreshed Claude observation'
    # A Codex-first tie-selected Claude gets its normal bounded refresh.
    Save-Usage 70 20 1
    $entry.PSObject.Properties.Remove('tie_evidence'); Save-Roster
    $beforeCalls = $script:guardCalls
    $null = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    $baselineCalls = $script:guardCalls - $beforeCalls
    Save-Usage 70 20 1
    $entry | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $evidence; Save-Roster
    $beforeCalls = $script:guardCalls
    $null = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Check ($baselineCalls -eq 0 -and $script:guardCalls - $beforeCalls -eq 1) 'Codex-first tie refreshes newly selected Claude once'

    $script:RouterClaudeUsageFetcher = { $script:guardCalls++; [pscustomobject]@{seven_day=[pscustomobject]@{utilization=97;resets_at=[datetimeoffset]::UtcNow.AddDays(1).ToString('o')}} }
    foreach ($codexUse in @(70,97)) {
        Save-Usage $codexUse 20 (10.0/60)
        $beforeCalls = $script:guardCalls
        $pick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
        Check ($pick.model -ne $entry.backup -and $script:guardCalls - $beforeCalls -eq 1) "stale low Claude cache refreshes to blocked 97 percent (Codex=$codexUse)"
    }
    # Catalog fallback must refresh Claude too, even when the tie retains Codex.
    Save-Usage 20 70 (10.0/60)
    $beforeCalls = $script:guardCalls
    $pick = Resolve-RouterModel -Category routine-coding -Catalog ([pscustomobject]@{models=@()})
    Check ($pick.status -eq 'wait' -and $script:guardCalls - $beforeCalls -eq 1) 'tie catalog fallback refreshes Claude and respects live block'

    $script:RouterClaudeCredentialProvider = { [pscustomobject]@{status='missing'} }
    Save-Usage 20 70 1
    $pick = Resolve-RouterModel -Category long-form-writing -Catalog $catalog
    Check ($pick.model -eq $writer.first -and $pick.reason -match 'stale or missing') 'missing normal Claude reading cannot reuse older cache'
    # Stale-incident recovery performs exactly the ordinary resolver's bounded calls.
    $script:RouterDiagnosisHttp = {
        param($Uri)
        $script:guardCalls++
        if ($Uri -like '*connecttest*') { return 'ok' }
        $lane = (Read-RouterJsonObject (Join-Path $PSScriptRoot '../../../references/model-router/vendor-status.json')).claude
        [pscustomobject]@{components=@($lane.components | ForEach-Object { [pscustomobject]@{id=$_;name=$_;status='operational'} })}
    }
    $script:RouterDiagnosisDns = { $script:guardCalls++; $true }
    $counts = @()
    foreach ($withTie in @($false,$true)) {
        Save-Usage 70 20
        $entry.PSObject.Properties.Remove('tie_evidence')
        if ($withTie) { $entry | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $evidence }
        Save-Roster
        Remove-Item (Join-Path $temp 'vendor-status-cache.json') -ErrorAction SilentlyContinue
        Write-RouterJsonAtomic (Join-Path $temp 'vendor-blocks.json') @(@{vendor='claude';reason='vendor_incident';component='synthetic';blocked_at_utc=[datetimeoffset]::UtcNow.AddMinutes(-10).ToString('o')})
        $beforeCalls = $script:guardCalls
        $null = Resolve-RouterModel -Category routine-coding -Catalog $catalog
        $counts += $script:guardCalls - $beforeCalls
    }
    Check ($counts[0] -gt 0 -and $counts[0] -eq $counts[1]) 'tie adds no calls beyond normal stale incident recovery'
    Write-RouterJsonAtomic (Join-Path $temp 'vendor-blocks.json') @()
    # Choosing Codex from a Claude-first tie cannot add a catalog refresh.
    function Get-CodexModelCatalog { [pscustomobject]@{models=@()} }
    $script:RouterClaudeCredentialProvider = { [pscustomobject]@{status='missing'} }
    $counts = @()
    foreach ($withTie in @($false,$true)) {
        Save-Usage 20 70
        $writer.PSObject.Properties.Remove('tie_evidence')
        if ($withTie) { $writer | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $writerEvidence }
        Save-Roster
        $beforeCalls = $script:guardCalls
        $pick = Resolve-RouterModel -Category long-form-writing
        $counts += $script:guardCalls - $beforeCalls
        Check ($pick.model -eq $writer.first) "unselectable Codex backup retains usable Claude (tie=$withTie)"
    }
    Check ($counts[0] -eq $counts[1]) 'tie adds no catalog refresh beyond same baseline resolve'
    $script:RouterClaudeCredentialProvider = { [pscustomobject]@{status='available';token='synthetic'} }
    $script:RouterClaudeUsageFetcher = { $script:guardCalls++; [pscustomobject]@{seven_day=[pscustomobject]@{utilization=$script:liveFallbackUse;resets_at=[datetimeoffset]::UtcNow.AddDays(1).ToString('o')}} }
    foreach ($liveUse in @(97,20)) {
        $script:liveFallbackUse = $liveUse
        Save-Usage 20 97 (10.0/60)
        $beforeCalls = $script:guardCalls
        $pick = Resolve-RouterModel -Category routine-coding
        Check ($script:guardCalls - $beforeCalls -eq 2) "catalog retry and ordinary Claude refresh both run (live=$liveUse)"
        Check (($liveUse -eq 97 -and $pick.status -eq 'wait') -or ($liveUse -eq 20 -and $pick.model -eq $entry.backup)) "catalog retry fallback uses live Claude block result (live=$liveUse)"
    }
    Write-Output "PASS: $script:passed tests; network and model guards active"
} finally {
    Exit-RouterTestCodexHome $fixture
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force
}
