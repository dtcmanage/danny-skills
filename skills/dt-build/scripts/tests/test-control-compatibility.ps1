#Requires -Version 7.0
# AI-139: control calls fail closed on unsupported input, echo what they persisted, and stale copies
# fail the capability preflight. Disposable temp run folders only; no live run is read or written.
param([string]$EvidencePath)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../../../scripts/lib/runtime-test-admission.ps1')
Enter-RuntimeTestSuite
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'operator-fixture-caller.ps1')
if (Test-OperatorFixtureAutomationCaller) {
    'SKIP: operator-only control compatibility fixtures require launching-session ancestry; DT_JOB_OPERATOR_ONLY protection retained.'
    exit 0
}
$scripts = Split-Path -Parent $PSScriptRoot
$dtJob = Join-Path $scripts 'dt-job.ps1'
$control = Join-Path $scripts 'invoke-dt-job-control.ps1'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scripts))
$root = Join-Path ([IO.Path]::GetTempPath()) ('control-compat-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$saved = @{}
foreach ($name in @('DT_BUILD_STATE_DIR', 'DT_BUILD_HEADLESS', 'DT_BUILD_COORDINATOR_ID', 'DT_JOB_ID')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$env:DT_BUILD_STATE_DIR = Join-Path $root 'registry'
$env:DT_BUILD_HEADLESS = '1'
Remove-Item Env:DT_BUILD_COORDINATOR_ID, Env:DT_JOB_ID -ErrorAction SilentlyContinue
$script:passed = 0; $script:failed = 0
$held = @()
$evidence = [ordered]@{ dt_job = $dtJob; dt_job_sha256 = (Get-FileHash -LiteralPath $dtJob -Algorithm SHA256).Hash.ToLowerInvariant(); checks = [Collections.Generic.List[object]]::new() }

function Check([bool]$Condition, [string]$Label) {
    if ($Condition) { $script:passed++; Write-Output "PASS: $Label" } else { $script:failed++; Write-Output "FAIL: $Label" }
    $evidence.checks.Add([ordered]@{ label = $Label; pass = $Condition })
}
function Run-Job([string]$Script, [string[]]$Arguments) {
    $raw = & pwsh -NoProfile -File $Script @Arguments 2>&1
    [pscustomobject]@{ exit = $LASTEXITCODE; text = (($raw | ForEach-Object { [string]$_ }) -join "`n") }
}
function Call-Job([string[]]$Arguments) {
    $entry = if ($Arguments[0] -in @('approve', 'decline', 'hold', 'note', 'delegate', 'resume')) { $control } else { $dtJob }
    $r = Run-Job $entry ($Arguments + @('-AllowTempRunFolder', '-Json'))
    if ($r.exit) { throw "dt-job $($Arguments -join ' ') exited $($r.exit): $($r.text)" }
    $r.text | ConvertFrom-Json
}
function Get-TreeSnapshot([string]$Path) {
    # Every file's relative path, size and hash: any write anywhere under the folder changes it.
    (@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        "$([IO.Path]::GetRelativePath($Path, $_.FullName))|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    }) -join "`n")
}
function Write-Utf8([string]$Path, [string]$Content) { [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false)) }
function New-Run([string]$Name, [string]$Operation, [string]$Status = 'awaiting_danny') {
    $rf = Join-Path $root $Name
    New-Item -ItemType Directory -Path $rf | Out-Null
    $state = Join-Path $rf '_build-state.md'
    Write-Utf8 $state "run_status: $Status`nlast_consumed_event_seq: 0`nupdated_utc: fixture`n"
    Call-Job @('register-run', '-RunFolder', $rf, '-RunId', $Name, '-BuildStatePath', $state, '-PinnedHost', 'codex', '-Managed') | Out-Null
    $awaiting = if ($Operation) { @{ operation = $Operation; seq = 1 } } else { $null }
    Write-Utf8 (Join-Path $rf 'approvals.json') (@{ awaiting = $awaiting; approvals = @(); delegate = $null } | ConvertTo-Json -Depth 5)
    [pscustomobject]@{ folder = $rf; state = $state; approvals = (Join-Path $rf 'approvals.json'); queue = (Join-Path $rf 'approval-queued.json') }
}
function Read-Json([string]$Path) { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
function Start-ClosingCoordinator([object]$Run) {
    # A live watcher-launched coordinator with no waiter: approvals queue until it exits.
    $p = Start-Process pwsh -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 600') -PassThru
    $script:held += $p
    $lease = [ordered]@{ coordinator_id = 'closing-' + [guid]::NewGuid().ToString('N'); launched_by = 'watcher'; pid = $p.Id; pid_start_utc = $p.StartTime.ToUniversalTime().ToString('o'); released_utc = $null }
    Write-Utf8 (Join-Path $Run.folder 'coordinator.lease') ($lease | ConvertTo-Json)
    $p
}

try {
    $me = [Environment]::UserName

    # ---- 1. Strict binding: unknown names, extra positional tokens and misplaced control parameters write nothing.
    $run = New-Run 'strict' 'pick-option'
    $before = Get-TreeSnapshot $run.folder
    $refusals = [ordered]@{
        'unknown named parameter' = @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Choice', 'B')
        'unknown switch' = @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Deny')
        'extra positional token' = @('approve', 'pick-option', '-RunFolder', $run.folder, '-Operation', 'pick-option')
        'unquoted multi-word reason' = @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Reason', 'Option', 'B')
        'Decline on resume' = @('resume', '-RunFolder', $run.folder, '-Decline')
        'Decline on note' = @('note', '-RunFolder', $run.folder, '-Message', 'fixture', '-Decline')
        'Decline on status' = @('status', '-RunFolder', $run.folder, '-Decline')
        'Decline on hold' = @('hold', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Reason', 'x', '-Decline')
        'Operation on resume' = @('resume', '-RunFolder', $run.folder, '-Operation', 'pick-option')
        'Clear on approve' = @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Clear')
        'Seq on approve' = @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Seq', '3')
        'invalid verb' = @('decline', '-RunFolder', $run.folder, '-Operation', 'pick-option')
    }
    foreach ($case in $refusals.Keys) {
        $r = Run-Job $dtJob ($refusals[$case] + @('-AllowTempRunFolder', '-Json'))
        $expected = if ($case -like 'unknown*') { 'cannot be found that matches parameter name' } elseif ($case -like '*positional*' -or $case -like '*multi-word*') { 'positional parameter cannot be found' } elseif ($case -eq 'invalid verb') { 'ValidateSet|does not belong to the set' } else { 'DT_JOB_USAGE: -\w+ applies only to' }
        Check ($r.exit -ne 0 -and $r.text -match $expected) "$case is refused ($expected)"
        Check ((Get-TreeSnapshot $run.folder) -ceq $before) "$case leaves every run-folder file unchanged"
    }
    Check (-not (Test-Path -LiteralPath $run.queue)) 'no refusal created an approval queue'

    # Every non-reader must reject Reason before run resolution or any filesystem mutation.
    $nonReaders = @('start','requeue','status','wait','cancel','reconcile','lease','register-run','unregister-run','pin','consume','await-danny','delegate','note','resume','finish','mark-bootstrap','irreversible','tree-hash','can-reuse','capabilities')
    foreach ($verb in $nonReaders) {
        $r = Run-Job $dtJob @($verb, '-RunFolder', $run.folder, '-Reason', 'must not disappear', '-AllowTempRunFolder', '-Json')
        Check ($r.exit -ne 0 -and $r.text -match 'DT_JOB_USAGE: -Reason applies only to' -and (Get-TreeSnapshot $run.folder) -ceq $before) "Reason on $verb refuses and preserves every run byte"
    }
    foreach ($case in $refusals.Keys) {
        # decline is an intentional convenience verb on the operator entry.
        if ($case -eq 'invalid verb') { continue }
        $r = Run-Job $control ($refusals[$case] + @('-AllowTempRunFolder', '-Json'))
        Check ($r.exit -ne 0 -and (Get-TreeSnapshot $run.folder) -ceq $before) "operator entry: $case refuses without writes"
    }
    foreach ($verb in @('note','delegate','resume')) {
        $r = Run-Job $control @($verb, '-RunFolder', $run.folder, '-Reason', 'not consumed', '-AllowTempRunFolder', '-Json')
        Check ($r.exit -ne 0 -and $r.text -match 'DT_JOB_CONTROL_USAGE' -and (Get-TreeSnapshot $run.folder) -ceq $before) "operator entry: Reason on $verb refuses without writes"
    }
    foreach ($invalid in @(
        @('note', '-Message', 'fixture', '-RunId', 'ignored'),
        @('note', '-Message', 'fixture', '-BuildStatePath', $run.state),
        @('note', '-Message', 'fixture', '-NoteId', ''),
        @('note', '-Clear', '-Message', 'ignored'),
        @('hold', '-Operation', 'pick-option', '-Clear', '-Reason', 'ignored'),
        @('delegate', '-Clear', '-Delegate', 'ignored')
    )) {
        $r = Run-Job $control ($invalid + @('-RunFolder', $run.folder, '-AllowTempRunFolder', '-Json'))
        Check ($r.exit -ne 0 -and $r.text -match 'DT_JOB_CONTROL_USAGE' -and (Get-TreeSnapshot $run.folder) -ceq $before) "operator entry: invalid combination $($invalid -join ' ') refuses without writes"
    }

    # Legitimate forms still bind: positional verb, named -Verb, -Verb:value, aliases and comma lists.
    $named = Call-Job @('-Verb', 'status', '-RunFolder', $run.folder)
    $colon = Call-Job @('-Verb:status', '-RunFolder', $run.folder)
    $positional = Call-Job @('status', '-RunFolder', $run.folder)
    Check ((@($named, $colon, $positional) | Where-Object { $_.run_folder -ceq [IO.Path]::GetFullPath($run.folder) }).Count -eq 3) 'positional, named and colon-bound verbs still bind'
    $leaseRun = New-Run 'aliases' $null 'runnable'
    # The lease names a separate disposable process: a lease naming this test would make it a coordinator ancestor.
    $aliasHolder = Start-Process pwsh -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 600') -PassThru
    $held += $aliasHolder
    Call-Job @('lease', '-RunFolder', $leaseRun.folder, '-CoordinatorId', 'alias-fixture', '-Action', 'acquire', '-Host', 'codex', '-Pid', "$($aliasHolder.Id)", '-TtlSec', '30') | Out-Null
    $lease = Read-Json (Join-Path $leaseRun.folder 'coordinator.lease')
    Check ($lease.pid -eq $aliasHolder.Id -and $lease.coordinator_id -eq 'alias-fixture') '-Host and -Pid aliases still bind under strict binding'
    Call-Job @('lease', '-RunFolder', $leaseRun.folder, '-CoordinatorId', 'alias-fixture', '-Action', 'release') | Out-Null
    $aliasHolder.Kill(); $aliasHolder.WaitForExit()
    $argScript = Join-Path $root 'echo-args.ps1'
    Write-Utf8 $argScript 'param([Parameter(ValueFromRemainingArguments)][string[]]$Rest) Write-Output ($Rest -join "|")'
    $job = Call-Job @('start', '-RunFolder', $leaseRun.folder, '-ScriptPath', $argScript, '-ArgumentList', 'one,two')
    $recordText = Get-Content -Raw -LiteralPath (Join-Path $leaseRun.folder "jobs/$($job.job_id)/spec.json")
    Check ($recordText -match '"argument_list"\s*:\s*(\[\s*)?"one,two"') 'start forwards -ArgumentList under strict binding'
    Call-Job @('wait', '-RunFolder', $leaseRun.folder, '-JobId', $job.job_id, '-TimeoutSec', '120') | Out-Null

    # ---- 2. Immediate approval: exact option, trimmed reason and actor are persisted and echoed.
    $run = New-Run 'immediate' 'pick-option'
    $out = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Reason', "  Option B: keep the gate.`n ")
    $rec = @((Read-Json $run.approvals).approvals)[-1]
    Check ($out.decision -eq 'approved' -and $out.approved -eq 'pick-option' -and $out.reason -ceq 'Option B: keep the gate.' -and $out.actor -ceq $me -and $out.await_seq -eq 1) 'immediate approve echoes decision, trimmed reason, actor and boundary'
    Check ($rec.reason -ceq 'Option B: keep the gate.' -and $rec.requested_by -ceq $me -and $rec.control_contract -eq 1 -and $out.recorded_utc -ceq $rec.requested_utc) 'immediate approve persists the same reason, actor and contract it echoes'
    Check ((Read-Json $run.approvals).awaiting -eq $null -and (Get-Content -Raw $run.state) -match 'run_status: runnable') 'immediate approve releases the boundary'
    $snap = Get-TreeSnapshot $run.folder
    $dup = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Reason', 'Option B: keep the gate.')
    $dupBare = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option')
    Check ($dup.duplicate -and $dup.reason -ceq 'Option B: keep the gate.' -and $dupBare.duplicate -and $dupBare.reason -ceq 'Option B: keep the gate.' -and $dupBare.actor -ceq $me) 'repeat approve is idempotent and echoes the persisted reason'
    Check (@((Read-Json $run.approvals).approvals).Count -eq 1 -and (Get-TreeSnapshot $run.folder) -ceq $snap) 'repeat approve records nothing new'
    $conflict = Run-Job $dtJob @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Reason', 'Option C', '-AllowTempRunFolder', '-Json')
    Check ($conflict.exit -ne 0 -and $conflict.text -match 'DT_JOB_APPROVE_CONFLICT' -and (Get-TreeSnapshot $run.folder) -ceq $snap) 'repeat approve with a different option is refused without writes'
    $late = Run-Job $dtJob @('approve', '-RunFolder', $run.folder, '-Operation', 'pick-option', '-Decline', '-Reason', 'no', '-AllowTempRunFolder', '-Json')
    Check ($late.exit -ne 0 -and $late.text -match 'DT_JOB_ALREADY_APPROVED' -and (Get-TreeSnapshot $run.folder) -ceq $snap) 'decline after an applied approval is refused, never reported as approved'

    # ---- 3. True decline: recorded as a decline, never an approval; the boundary stays stopped.
    $run = New-Run 'decline' 'closeout-gaps'
    $out = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'closeout-gaps', '-Decline', '-Reason', '  Gaps must be fixed first. ')
    $a = Read-Json $run.approvals
    Check ($out.decision -eq 'declined' -and $out.declined -eq 'closeout-gaps' -and -not $out.PSObject.Properties['approved'] -and $out.reason -ceq 'Gaps must be fixed first.' -and $out.actor -ceq $me) 'decline echoes decision=declined, trimmed reason and actor'
    Check (@($a.approvals).Count -eq 0 -and $a.awaiting.operation -eq 'closeout-gaps' -and $a.awaiting.declined.reason -ceq 'Gaps must be fixed first.' -and $a.awaiting.declined.control_contract -eq 1) 'decline persists on the boundary and records no approval'
    Check ((Get-Content -Raw $run.state) -match 'run_status: awaiting_danny') 'decline leaves the run stopped'
    $again = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'closeout-gaps', '-Decline', '-Reason', 'Still no.')
    $a = Read-Json $run.approvals
    Check ($again.reason -ceq 'Still no.' -and $a.awaiting.declined.superseded_decline.reason -ceq 'Gaps must be fixed first.') 'a second decline keeps the first on the record'
    $over = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'closeout-gaps', '-Reason', 'Danny reversed: proceed.')
    $rec = @((Read-Json $run.approvals).approvals)[-1]
    Check ($over.decision -eq 'approved' -and $rec.overruled_decline.reason -ceq 'Still no.' -and $rec.reason -ceq 'Danny reversed: proceed.') 'a later explicit approval overrules and preserves the decline'
    $aliasRun = New-Run 'decline-alias' 'pick-option'
    $aliasDecision = Call-Job @('decline', '-RunFolder', $aliasRun.folder, '-Operation', 'pick-option', '-Reason', 'Exact choice B; $literal')
    Check ($aliasDecision.decision -eq 'declined' -and $aliasDecision.reason -ceq 'Exact choice B; $literal' -and (Read-Json $aliasRun.approvals).awaiting.declined.reason -ceq $aliasDecision.reason) 'decline entry forwards exact choice without shell interpretation'
    if (-not $IsWindows) {
        $link = Join-Path $root 'linked-skill'
        New-Item -ItemType SymbolicLink -Path $link -Target (Split-Path -Parent $scripts) | Out-Null
        $linkRun = New-Run 'linked-entry' 'pick-option'
        $r = Run-Job (Join-Path $link 'scripts/invoke-dt-job-control.ps1') @('approve', '-RunFolder', $linkRun.folder, '-Operation', 'pick-option', '-Decline', '-Reason', 'Choice through skill link', '-AllowTempRunFolder', '-Json')
        $linkedDecision = $r.text | ConvertFrom-Json
        Check ($r.exit -eq 0 -and $linkedDecision.decision -eq 'declined' -and $linkedDecision.reason -ceq 'Choice through skill link') 'supported entry resolves the canonical sibling through a skill directory link'
        Remove-Item -LiteralPath $link -Force
    }

    # ---- 4. Queued approval: echo, duplicate, conflict, consume after coordinator exit, idempotent repeat.
    $run = New-Run 'queued' 'merge-option'
    $closing = Start-ClosingCoordinator $run
    $out = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'merge-option', '-Reason', ' Option A ')
    $q = Read-Json $run.queue
    Check ($out.decision -eq 'approval_queued' -and $out.approval_queued -eq 'merge-option' -and $out.reason -ceq 'Option A' -and $out.actor -ceq $me -and $out.message -match "coordinator $($closing.Id) exits") 'queued approve echoes decision, reason and actor'
    Check ($q.status -eq 'queued' -and $q.reason -ceq 'Option A' -and $q.requested_by -ceq $me -and $q.control_contract -eq 1) 'queued receipt persists the echoed reason and actor'
    $snap = Get-TreeSnapshot $run.folder
    $dup = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'merge-option')
    Check ($dup.duplicate -and $dup.decision -eq 'approval_queued' -and $dup.reason -ceq 'Option A' -and (Get-TreeSnapshot $run.folder) -ceq $snap) 'repeat queued approve echoes the original receipt and writes nothing'
    $conflict = Run-Job $dtJob @('approve', '-RunFolder', $run.folder, '-Operation', 'merge-option', '-Reason', 'Option B', '-AllowTempRunFolder', '-Json')
    Check ($conflict.exit -ne 0 -and $conflict.text -match 'DT_JOB_APPROVE_CONFLICT' -and (Get-TreeSnapshot $run.folder) -ceq $snap) 'queued approve with a different option is refused without writes'
    $closing.Kill(); $closing.WaitForExit()
    Call-Job @('status', '-RunFolder', $run.folder) | Out-Null
    $a = Read-Json $run.approvals
    Check (@($a.approvals).Count -eq 1 -and $a.approvals[0].reason -ceq 'Option A' -and $a.approvals[0].requested_by -ceq $me -and $a.approvals[0].status -eq 'applied' -and $null -eq $a.awaiting) 'consumed queued approval keeps the exact option and actor'
    $repeat = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'merge-option')
    Check ($repeat.duplicate -and $repeat.reason -ceq 'Option A' -and @((Read-Json $run.approvals).approvals).Count -eq 1) 'approve after consumption is idempotent and echoes the consumed reason'

    # ---- 5. Decline withdraws a queued approval; it never applies after the coordinator exits.
    $run = New-Run 'queued-decline' 'merge-option'
    $closing = Start-ClosingCoordinator $run
    Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'merge-option', '-Reason', 'Option A') | Out-Null
    $out = Call-Job @('approve', '-RunFolder', $run.folder, '-Operation', 'merge-option', '-Decline', '-Reason', 'Changed my mind.')
    $q = Read-Json $run.queue
    Check ($out.decision -eq 'declined' -and $q.status -eq 'withdrawn' -and $q.reason -ceq 'Option A') 'decline withdraws the queued approval and keeps it on the record'
    $closing.Kill(); $closing.WaitForExit()
    Call-Job @('status', '-RunFolder', $run.folder) | Out-Null
    $a = Read-Json $run.approvals
    Check (@($a.approvals).Count -eq 0 -and $a.awaiting.declined.reason -ceq 'Changed my mind.' -and $a.awaiting.declined.withdrew_queued_approval.reason -ceq 'Option A' -and (Get-Content -Raw $run.state) -match 'run_status: awaiting_danny') 'withdrawn approval never applies after the coordinator exits'

    # ---- 6. Capability preflight: the current copy describes itself; the stale copy fails before any write.
    $allBefore = Get-TreeSnapshot $root
    $caps = Call-Job @('capabilities')
    Check ((Get-TreeSnapshot $root) -ceq $allBefore) 'canonical capabilities is side effect free across all disposable files'
    Check ($caps.control_contract -ge 1 -and $caps.decline -and $caps.persists_reason -and $caps.strict_binding -and $caps.sha256 -ceq $evidence.dt_job_sha256 -and $caps.script_path -ceq [IO.Path]::GetFullPath($dtJob)) 'capabilities reports contract, path and hash of the running copy'
    $evidence.capabilities = $caps
    $staleDir = Join-Path $root 'stale-copy/scripts'
    New-Item -ItemType Directory -Path $staleDir -Force | Out-Null
    $stalePath = Join-Path $staleDir 'dt-job.ps1'
    # Model the old public binding contract, without requiring .git/history in
    # release archives or baseline exports. Any accidental control execution fails.
    Write-Utf8 $stalePath 'param([ValidateSet("approve","status")][string]$Verb,[string]$RunFolder,[switch]$AllowTempRunFolder,[switch]$Json) throw "STALE_CONTROL_MUST_NOT_RUN"'
    $evidence.stale_fixture = [ordered]@{ source = 'self-contained pre-capabilities binding contract'; sha256 = (Get-FileHash -LiteralPath $stalePath -Algorithm SHA256).Hash.ToLowerInvariant() }
    $staleRun = New-Run 'stale' 'pick-option'
    $before = Get-TreeSnapshot $staleRun.folder
    $staleBefore = Get-TreeSnapshot (Split-Path -Parent $staleDir)
    $pre = Run-Job $stalePath @('capabilities', '-RunFolder', $staleRun.folder, '-AllowTempRunFolder', '-Json')
    Check ($pre.exit -ne 0 -and $pre.text -match 'capabilities' -and (Get-TreeSnapshot $staleRun.folder) -ceq $before -and (Get-TreeSnapshot (Split-Path -Parent $staleDir)) -ceq $staleBefore) 'stale copy fails the capability preflight without any write'
    $evidence.stale_preflight = [ordered]@{ exit = $pre.exit; text = ($pre.text -split "`n" | Select-Object -First 3) -join ' ' }
    $allBefore = Get-TreeSnapshot $root
    $staleControl = Run-Job $control @('approve', '-TargetPath', $stalePath, '-RunFolder', $staleRun.folder, '-Operation', 'pick-option', '-Decline', '-Reason', 'REFUSE this choice', '-AllowTempRunFolder', '-Json')
    Check ($staleControl.exit -ne 0 -and $staleControl.text -match 'DT_JOB_CONTROL_PREFLIGHT' -and (Get-TreeSnapshot $root) -ceq $allBefore) 'supported entry refuses stale approve -Decline -Reason before running approve; ALL disposable files byte-identical'
    $evidence.stale_operator_entry = @{ exit = $staleControl.exit; text = $staleControl.text; all_files_unchanged = ((Get-TreeSnapshot $root) -ceq $allBefore) }

    # Contract flags, resolved identity and hash are all mandatory, even for an override.
    $fake = Join-Path $root 'fake-target.ps1'
    $fakeSource = 'param($Verb,[switch]$Json) if ($Verb -ne "capabilities") { throw "CONTROL_MUST_NOT_RUN" }; $caps = @{control_contract=1;decline=$true;persists_reason=$true;strict_binding=$true;script_path=$PSCommandPath;sha256=(Get-FileHash $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()}; $caps.BAD_FIELD=BAD_VALUE; $caps | ConvertTo-Json -Compress'
    foreach ($field in @('control_contract','decline','persists_reason','strict_binding','script_path','sha256','string_flag')) {
        $value = switch ($field) { 'control_contract' { '0' } 'script_path' { '"wrong-path"' } 'sha256' { '"wrong-hash"' } default { '$false' } }
        $label = $field
        if ($field -eq 'string_flag') { $field = 'decline'; $value = '"true"' }
        Write-Utf8 $fake ($fakeSource.Replace('BAD_FIELD', $field).Replace('BAD_VALUE', $value))
        $snapshot = Get-TreeSnapshot $root
        $refused = Run-Job $control @('approve', '-TargetPath', $fake, '-RunFolder', $staleRun.folder, '-Operation', 'pick-option', '-Decline', '-Reason', 'no', '-Json')
        Check ($refused.exit -ne 0 -and $refused.text -match 'DT_JOB_CONTROL_PREFLIGHT' -and $refused.text -notmatch 'CONTROL_MUST_NOT_RUN' -and (Get-TreeSnapshot $root) -ceq $snapshot) "operator preflight refuses invalid $label without running control or writing"
    }

    # The wrapper retains the automation environment; it cannot grant operator authority.
    $env:DT_JOB_ID = 'unauthorized-worker'
    $snapshot = Get-TreeSnapshot $root
    $denied = Run-Job $control @('approve', '-RunFolder', $staleRun.folder, '-Operation', 'pick-option', '-Reason', 'worker request', '-AllowTempRunFolder', '-Json')
    Remove-Item Env:DT_JOB_ID
    Check ($denied.exit -ne 0 -and $denied.text -match 'DT_JOB_OPERATOR_ONLY' -and (Get-TreeSnapshot $root) -ceq $snapshot) 'operator entry preserves worker authority refusal and every disposable byte'
}
finally {
    foreach ($p in $held) { try { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() } } catch { } }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    $evidence.passed = $script:passed; $evidence.failed = $script:failed
    if ($EvidencePath) { [IO.File]::WriteAllText($EvidencePath, ($evidence | ConvertTo-Json -Depth 8)) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "passed=$script:passed failed=$script:failed"
if ($script:failed) { exit 1 }
exit 0
