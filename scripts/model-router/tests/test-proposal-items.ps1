Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../router-common.ps1')
$script:passed = 0
function Assert-True([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('proposal-items-' + [guid]::NewGuid().ToString('N'))
$state = Join-Path $temp 'state'
$saved = @{}
foreach ($name in @('DT_MODEL_ROUTER_STATE','DT_ROUTER_CC_COMMAND','DT_ROUTER_TEST_FAKE_CLI_ROOT','DT_PROPOSAL_CC_ROOT','DT_PROPOSAL_CC_FAIL')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
[IO.Directory]::CreateDirectory($state) | Out-Null
$env:DT_MODEL_ROUTER_STATE = $state
$env:DT_PROPOSAL_CC_ROOT = $temp
$env:DT_PROPOSAL_CC_FAIL = ''
$fake = Join-Path $temp 'cc.ps1'
[IO.File]::WriteAllText($fake, @'
$ErrorActionPreference = 'Stop'
$root = $env:DT_PROPOSAL_CC_ROOT
Add-Content -LiteralPath (Join-Path $root 'calls.jsonl') -Value (ConvertTo-Json -InputObject @($args) -Compress)
if ($env:DT_PROPOSAL_CC_FAIL) { throw 'FAKE_CC_FAILURE' }
$db = Join-Path $root 'items.json'
$items = @(if (Test-Path $db) { Get-Content $db -Raw | ConvertFrom-Json })
switch ($args[0]) {
    list { ConvertTo-Json -InputObject @($items | Where-Object status -eq open) -Depth 15 -Compress }
    add {
        $fields = @{}
        for ($i=1; $i -lt $args.Count; $i+=2) { $fields[$args[$i].Substring(2).Replace('-','_')] = $args[$i+1] }
        $existing = @($items | Where-Object thread_key -eq $fields.thread_key)
        if ($existing.Count) { $item = $existing[0] }
        else {
            $item = [pscustomobject]$fields
            $item | Add-Member id ([guid]::NewGuid().ToString('N'))
            $item | Add-Member num ($items.Count+1)
            $item | Add-Member status open
            $item | Add-Member done_note ''
            $items += $item
            ConvertTo-Json -InputObject $items -Depth 15 | Set-Content $db
        }
        "#$($item.num) $($item.title)"
        $item | ConvertTo-Json -Depth 15 -Compress
    }
    done {
        if ($args[1] -notlike 'id:*') { throw 'MUST_USE_PERMANENT_ID' }
        $item = $items | Where-Object id -eq $args[1].Substring(3)
        $item.status = 'done'; $item.done_note = $args[3]
        ConvertTo-Json -InputObject $items -Depth 15 | Set-Content $db
    }
    default { throw 'BAD_CC_VERB' }
}
'@)
$env:DT_ROUTER_CC_COMMAND = $fake
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixture = Enter-RouterTestCodexHome
function Invoke-Sync([switch]$DryRun) {
    $raw = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../sync-proposal-items.ps1') -StateDir $state -Json -DryRun:$DryRun
    Assert-True ($LASTEXITCODE -eq 0) 'reconciler exits zero' | Out-Host
    return ($raw | ConvertFrom-Json -Depth 20)
}
function Read-Items { return @(Get-Content (Join-Path $temp 'items.json') -Raw | ConvertFrom-Json -Depth 20) }
try {
    $tiePath = Join-Path $state 'tie-proposals/deep-thinker.json'
    $tie = [pscustomobject]@{type='tie';job='deep-thinker';tier='standard';run_id='run-one';status='pending';configurations=@{candidate=@{model='claude-opus-5-5';effort='medium'};incumbent=@{model='gpt-6.1-sol';effort='medium'}}}
    Write-RouterJsonAtomic $tiePath $tie
    $effortPath = Join-Path $state 'effort-proposals/coder-standard.json'
    $effort = [pscustomobject]@{type='effort-swap';job='coder';tier='standard';model='gpt-6.1-sol';current_effort='medium';proposed_effort='high';report='C:/reports/effort-run/report.md';status='pending';created_at='2026-11-15T22:41:00Z'}
    $effort | Add-Member incumbent @{passed=5}
    $effort | Add-Member effort_up @{passed=7}
    Write-RouterJsonAtomic $effortPath $effort
    $rosterPath = Join-Path $state 'roster-proposals/latest.json'
    $proposal = [pscustomobject]@{approved=$false;generated_at='2026-11-15T22:41:00Z';pass_id='pass-one';validation_errors=@();changes=@(@{job='coder';slot='first';from='old';to='gpt-6-luna'})}
    Write-RouterJsonAtomic $rosterPath $proposal
    $frontierPath = Join-Path $state 'frontier-requests/request-one.json'
    $request = [pscustomobject]@{id='request-one';category='planning';status='pending';proposed_model='gpt-6-astra';created_at='2026-11-15T22:41:00Z'}
    Write-RouterJsonAtomic $frontierPath $request
    $result = Invoke-Sync
    $items = Read-Items
    Assert-True ($items.Count -eq 4 -and $result.added.Count -eq 4 -and $result.errors.Count -eq 0) 'four stores file four items'
    $expected = @{
        'router-proposal/tie/deep-thinker/run-one'='Approve or decline the deep-thinker Opus/Sol tie'
        'router-proposal/effort/coder-standard/effort-run'='Approve or decline raising coder effort from medium to high'
        'router-proposal/roster/latest/pass-one'="Approve or decline the router's proposed model changes"
        'router-proposal/frontier/request-one/request-one'='Approve or decline a frontier model request for planning'
    }
    foreach ($item in $items) {
        Assert-True ($expected[$item.thread_key] -eq $item.title) "friendly title and instance key $($item.thread_key)"
        Assert-True ($item.workstation -eq 'Skill Creation' -and $item.kind -eq 'needs-you' -and $item.area -eq 'build' -and $item.next_action -eq 'Say approve or decline.') 'owner item fields'
        Assert-True ($item.context -match 'Proposed .+ ET\.' -and $item.starter_prompt -match 'confirm the live roster' -and $item.details -match 'cd ".+"\r?\npwsh') 'ET context and actionable commands'
    }
    Assert-True (($items | Where-Object thread_key -like '*/effort/*').context -match '2026-11-15 5:41 PM ET') 'Eastern standard time conversion'
    Assert-True (($items | Where-Object thread_key -like '*/effort/*').context -match 'current choice passed 5 tasks; higher effort passed 7 tasks') 'context includes recorded pass counts'
    $again = Invoke-Sync
    Assert-True ($again.added.Count -eq 0 -and (Read-Items).Count -eq 4) 'rerun adds nothing'
    foreach ($status in @('approved','declined','revoked','superseded')) {
        if ($status -ne 'approved') { $tie.run_id = 'run-' + $status; $tie.status='pending'; Write-RouterJsonAtomic $tiePath $tie; $null = Invoke-Sync }
        $tie.status = $status
        $tie | Add-Member decided_at '2026-11-15T22:41:00Z' -Force
        Write-RouterJsonAtomic $tiePath $tie
        $result = Invoke-Sync
        Assert-True ($result.closed.Count -eq 1 -and $result.closed[0].note -ceq "$([Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($status)) 2026-11-15 5:41 PM ET.") "$status closes with exact note and stable key"
    }
    Remove-Item -LiteralPath $frontierPath
    $result = Invoke-Sync
    Assert-True ($result.closed.Count -eq 1 -and $result.closed[0].note -ceq 'No longer pending.') 'deleted proposal closes'
    $callCount = @(Get-Content (Join-Path $temp 'calls.jsonl')).Count
    $env:DT_ROUTER_CC_COMMAND = ''
    $result = Invoke-Sync
    Assert-True ($result.skipped -eq 'non-live-state' -and @(Get-Content (Join-Path $temp 'calls.jsonl')).Count -eq $callCount) 'non-live fixture without explicit command never lists CC'
    $env:DT_ROUTER_CC_COMMAND = Join-Path $temp 'missing.ps1'
    $result = Invoke-Sync
    Assert-True ($result.skipped -eq 'cc-unavailable') 'missing CLI no-ops'
    $env:DT_ROUTER_CC_COMMAND = $fake
    $result = Invoke-Sync -DryRun
    Assert-True ($result.added.Count -eq 2 -and @(Get-Content (Join-Path $temp 'calls.jsonl')).Count -eq $callCount) 'dry-run previews without CLI calls'
    $env:DT_PROPOSAL_CC_FAIL = '1'
    $result = Invoke-Sync
    Assert-True ($result.errors.Count -eq 1 -and (Get-Content (Join-Path $state 'proposal-items.log') -Raw) -match 'FAKE_CC_FAILURE') 'CC failure logs and exits zero'
    $env:DT_PROPOSAL_CC_FAIL = ''
    # Approval hook integration uses actual bank evidence and an isolated catalog.
    $current = Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
    $current.approved=$true; $current.approved_at='2026-11-15T22:41:00Z'
    Write-RouterJsonAtomic (Join-Path $state 'roster.json') $current
    $entry = $current.jobs.'deep-thinker'
    $tie.status='pending'; $tie.run_id='approval-hook'; $tie.PSObject.Properties.Remove('decided_at')
    $tie.configurations = @{candidate=@{model=$entry.first;effort=$entry.first_effort};incumbent=@{model=$entry.backup;effort=$entry.backup_effort}}
    $tie | Add-Member bank_hash (Get-RouterBenchEvidenceContext).task_bank_sha256 -Force
    Write-RouterJsonAtomic $tiePath $tie
    $null = Invoke-Sync
    $null = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') -ApproveTie -Job deep-thinker
    Assert-True ($LASTEXITCODE -eq 0) 'ApproveTie succeeds with fake CC'
    $item = Read-Items | Where-Object thread_key -eq 'router-proposal/tie/deep-thinker/approval-hook'
    Assert-True ($item.status -eq 'done' -and $item.done_note -match '^Approved .+ ET\.$') 'ApproveTie hook closes permanent item id'
    # Approved inline latest and invalid proposals never create decisions.
    $proposal.approved=$true; Write-RouterJsonAtomic $rosterPath $proposal
    $result = Invoke-Sync
    Assert-True ($result.closed.Count -eq 1 -and $result.closed[0].key -like '*/roster/*') 'approved inline latest closes'
    $proposal.approved=$false; $proposal.validation_errors=@('invalid'); $proposal.pass_id='invalid-pass'
    Write-RouterJsonAtomic $rosterPath $proposal
    $result = Invoke-Sync
    Assert-True ($result.added.Count -eq 0) 'invalid roster not awaiting approval'
    # latest pointers resolve only within the copied store. Partial approvals stay open.
    $proposal.validation_errors=@(); $proposal.pass_id='pointer-pass'
    $proposal.changes=@([pscustomobject]@{job='coder';slot='first';from='gpt-6.1-sol';to='gpt-6-luna'},[pscustomobject]@{job='fast';slot='first';from='old';to=$current.jobs.fast.first})
    $target = Join-Path $state 'roster-proposals/pointer.json'
    Write-RouterJsonAtomic $target $proposal
    Write-RouterJsonAtomic $rosterPath @{proposal='D:/must-not-read-live/pointer.json';report='evidence.md'}
    $current.approved_at='2026-11-16T00:00:00Z'
    Write-RouterJsonAtomic (Join-Path $state 'roster.json') $current
    $result = Invoke-Sync
    Assert-True ($result.added.Count -eq 1 -and $result.added[0] -eq 'router-proposal/roster/pointer/pointer-pass') 'local pointer and partial approval retain decision'
    $current.jobs.coder.first='gpt-6-luna'
    Write-RouterJsonAtomic (Join-Path $state 'roster.json') $current
    $result = Invoke-Sync
    Assert-True ($result.closed.Count -eq 1 -and $result.closed[0].note -like 'Approved * ET.') 'applied roster changes close without proposal mutation'
    $current.jobs.coder.first='gpt-6.1-sol'
    Write-RouterJsonAtomic (Join-Path $state 'roster.json') $current
    $proposal.pass_id='new-pass'; Write-RouterJsonAtomic $target $proposal
    $result = Invoke-Sync
    Assert-True ($result.added.Count -eq 1) 'new roster instance survives old closed item'
    $proposal.pass_id='replacement-pass'; Write-RouterJsonAtomic $target $proposal
    $result = Invoke-Sync
    Assert-True ($result.added.Count -eq 1 -and $result.closed.Count -eq 1 -and $result.closed[0].note -like 'Superseded * ET.') 'replacement instance supersedes old item'
    Write-RouterJsonAtomic (Join-Path $state 'drift-declines.json') @(@{job='coder';model='gpt-6.1-sol';declined_at='2026-11-16T00:00:00Z'},@{job='fast';model='gpt-6-luna';declined_at='2026-11-16T00:00:00Z'})
    $result = Invoke-Sync
    Assert-True ($result.closed.Count -eq 1 -and $result.closed[0].note -like 'Declined * ET.') 'declined drift settles roster decision'
    # Bad input must not make valid open items appear deleted.
    [IO.File]::WriteAllText($target, '{broken')
    $result = Invoke-Sync
    Assert-True ($result.errors.Count -eq 1 -and $result.closed.Count -eq 0) 'malformed snapshot never closes items'
    Write-RouterJsonAtomic $target $proposal
    $global:LASTEXITCODE = 37
    $env:DT_PROPOSAL_CC_FAIL = '1'
    Sync-RouterProposalItems -StateDir $state
    Assert-True ($global:LASTEXITCODE -eq 37) 'best-effort hook preserves caller exit code'
    $env:DT_PROPOSAL_CC_FAIL = ''
    Write-Output "All $script:passed proposal item tests passed."
} finally {
    Exit-RouterTestCodexHome $fixture
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
    # This run owns exactly this resolved temp subtree.
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
