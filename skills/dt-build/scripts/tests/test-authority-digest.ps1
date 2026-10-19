#Requires -Version 7.0
# Fixtures only: no Python, grader, vendor or model processes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ASSERT_FAIL: $Message" }
    $script:passed++; Write-Output "PASS: $Message"
}
$scripts = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('authority-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function Write-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
function Invoke-Fixture([string]$Script, [string[]]$Extra = @()) {
    $raw = & pwsh -NoProfile -File (Join-Path $scripts $Script) -RunFolder $root -BuildStatePath (Join-Path $root '_build-state.md') @Extra 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($raw -join "`n") }
}
function Pin-Manifest($Manifest) {
    Write-Text (Join-Path $root 'authority-digest.json') ($Manifest | ConvertTo-Json -Depth 8)
    Write-Text (Join-Path $root 'authority-digest.json.sha256') (Get-FileHash (Join-Path $root 'authority-digest.json')).Hash.ToLowerInvariant()
}
$operatorEnvironment = @{}
foreach ($identity in @('DT_JOB_ID', 'DT_BUILD_COORDINATOR_ID')) {
    $operatorEnvironment[$identity] = [Environment]::GetEnvironmentVariable($identity)
    [Environment]::SetEnvironmentVariable($identity, $null, 'Process')
}
try {
    $old = Join-Path $root 'old boundary.md'
    $current = Join-Path $root 'current-boundary.md'
    $approval = Join-Path $root 'approval.md'
    $checkpoint = Join-Path $root '_build-state.md'
    Write-Text $old "# Inherited boundary`nScope: fixtures only; never deploy.`nHistorical detail."
    Write-Text $approval 'Approved: fixture changes only. No production writes.'
    New-Item -ItemType Directory -Path (Join-Path $root 'approvals') | Out-Null
    Write-Text (Join-Path $root 'approvals/r3b3.md') 'Approved: source-only recovery. Never deploy.'
    Write-Text $current "# Current boundary`nOnly source changes. Approval: ``approval.md```nAlso see approvals/r3b3.md."
    Write-Text $checkpoint "run_status: runnable`nInherited: ``old boundary.md```nCurrent boundary: [current](current-boundary.md)"
    Write-Text (Join-Path $root 'approvals.json') '{"approvals":[{"source":"approval.md"}]}'
    $built = Invoke-Fixture 'build-authority-digest.ps1'
    Assert-True ($built.code -eq 0) 'deterministic build verifies its published pair'
    $verified = Invoke-Fixture 'verify-authority-digest.ps1'
    $result = $verified.text | ConvertFrom-Json
    Assert-True ($result.mode -eq 'originals' -and $result.verified) 'small authority set retains full-original bootstrap'
    $manifest = Get-Content (Join-Path $root 'authority-digest.json') -Raw | ConvertFrom-Json
    Assert-True (@($manifest.originals).Count -eq 5 -and @($manifest.originals | Where-Object { $_.path -eq $approval }).Count -eq 1 -and @($manifest.originals | Where-Object { $_.path -eq (Join-Path $root 'approvals/r3b3.md') }).Count -eq 1) 'recursive boundary references, bare relative approval paths and complete approvals are covered once'
    Assert-True ($result.mandatory_paths -contains $current -and $result.mandatory_paths -contains $approval -and $result.mandatory_paths -contains $checkpoint) 'current boundary, approvals and checkpoint always remain full reads'
    Assert-True (@($manifest.originals | Where-Object { $_.sha256.Length -ne 64 -or $_.bytes -le 0 -or -not $_.kind -or -not $_.extract }).Count -eq 0) 'every original has a hash, byte size, kind and mechanical extract'
    $digestPath = Join-Path $root 'authority-digest.json'
    $beforeEvidence = (Get-FileHash $digestPath).Hash
    $raw = & pwsh -NoProfile -File (Join-Path $scripts 'dt-job.ps1') note -RunFolder $root -Evidence -Message 'Observed fixture completion.' -Json
    Assert-True ($LASTEXITCODE -eq 0) 'operator adds an evidence note after digest build'
    Assert-True ((Invoke-Fixture 'verify-authority-digest.ps1').code -eq 0 -and (Get-FileHash $digestPath).Hash -eq $beforeEvidence) 'evidence add preserves verification and byte-identical digest JSON'
    [IO.File]::AppendAllText($checkpoint, "`nEvidence: ``evidence-notes.json``")
    Assert-True ((Invoke-Fixture 'build-authority-digest.ps1').code -eq 0) 'checkpoint literal evidence locator builds'
    $withEvidence = Get-Content $digestPath -Raw | ConvertFrom-Json
    Assert-True (@($withEvidence.originals | Where-Object { (Split-Path -Leaf $_.path) -ieq 'evidence-notes.json' }).Count -eq 0 -and @($withEvidence.diagnostics | Where-Object { $_.reason -eq 'evidence_only' -and -not $_.required }).Count -eq 1) 'literal evidence file is excluded with evidence_only diagnostic'
    $beforeEvidence = (Get-FileHash $digestPath).Hash
    Write-Text (Join-Path $root 'evidence-notes.json') '{"notes":[{"id":"e-002","text":"Changed observation."}]}'
    Assert-True ((Invoke-Fixture 'verify-authority-digest.ps1').code -eq 0 -and (Get-FileHash $digestPath).Hash -eq $beforeEvidence) 'named evidence changes never invalidate or rewrite digest'
    Assert-True ((Invoke-Fixture 'build-authority-digest.ps1').code -eq 0 -and (Get-FileHash $digestPath).Hash -eq $beforeEvidence) 'rebuilding after evidence changes publishes byte-identical JSON'
    $savedCurrent = [IO.File]::ReadAllText($current)
    Write-Text $current ($savedCurrent + "`nEvidence boundary locator: ``EVIDENCE-NOTES.json``")
    Assert-True ((Invoke-Fixture 'build-authority-digest.ps1').code -eq 0) 'boundary literal evidence locator is informational'
    $boundaryEvidence = Get-Content $digestPath -Raw | ConvertFrom-Json
    Assert-True (@($boundaryEvidence.originals | Where-Object { (Split-Path -Leaf $_.path) -ieq 'evidence-notes.json' }).Count -eq 0 -and @($boundaryEvidence.diagnostics | Where-Object reason -eq 'evidence_only').Count -eq 2) 'boundary discovery excludes case-insensitive evidence leaf without reading its data'
    Write-Text $current $savedCurrent
    Invoke-Fixture 'build-authority-digest.ps1' | Out-Null
    Remove-Item -LiteralPath (Join-Path $root 'evidence-notes.json')
    Assert-True ((Invoke-Fixture 'verify-authority-digest.ps1').code -eq 0) 'missing named evidence remains informational'
    $raw = & pwsh -NoProfile -File (Join-Path $scripts 'dt-job.ps1') note -RunFolder $root -Message 'Approved fixture changes only.' -Json
    Assert-True ($LASTEXITCODE -eq 0 -and (Invoke-Fixture 'verify-authority-digest.ps1').code -ne 0) 'normal operator note still changes pinned authority coverage'
    Assert-True ((Invoke-Fixture 'build-authority-digest.ps1').code -eq 0 -and (Get-FileHash $digestPath).Hash -ne $beforeEvidence) 'normal operator note changes rebuilt digest JSON'
    $raw = & pwsh -NoProfile -File (Join-Path $scripts 'dt-job.ps1') note -RunFolder $root -Message 'Only fixture scope.' -Json
    Assert-True ((Invoke-Fixture 'verify-authority-digest.ps1').text.Contains('AUTHORITY_ORIGINAL_HASH')) 'editing existing normal notes still invalidates pinned hash'
    Remove-Item -LiteralPath (Join-Path $root 'operator-notes.json')
    Write-Text $checkpoint (([IO.File]::ReadAllText($checkpoint)).Replace("`nEvidence: ``evidence-notes.json``", ''))
    Invoke-Fixture 'build-authority-digest.ps1' | Out-Null
    $source = Invoke-Fixture 'read-authority-original.ps1' @('-Path', $old)
    Assert-True ($source.code -eq 0 -and $source.text.Contains('Historical detail.')) 'action reader emits the complete original, including non-operative detail'
    Write-Text $checkpoint (([IO.File]::ReadAllText($checkpoint)).Replace('run_status: runnable', "run_status: awaiting_danny`nlast_consumed_event_seq: 7"))
    $ownedChanged = Invoke-Fixture 'verify-authority-digest.ps1'
    Assert-True ($ownedChanged.code -eq 0) 'operator resume and cursor changes leave authority verification intact'
    [IO.File]::AppendAllText($checkpoint, "`nBoundary: production deploy permitted")
    $changedScope = Invoke-Fixture 'verify-authority-digest.ps1'
    Assert-True ($changedScope.code -ne 0 -and $changedScope.text.Contains('AUTHORITY_CHECKPOINT_HASH')) 'checkpoint authority changes still fail closed'
    Write-Text $checkpoint (([IO.File]::ReadAllText($checkpoint)).Replace("`nBoundary: production deploy permitted", ''))
    Write-Text $old "Scope: fixtures only. Never deploy.`n$('history ' * 6000)"
    (Get-Item $old).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
    $bad = Invoke-Fixture 'verify-authority-digest.ps1'
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_ORIGINAL_HASH')) 'changed original fails verification closed'
    $bad = Invoke-Fixture 'read-authority-original.ps1' @('-Path', $old)
    Assert-True ($bad.code -ne 0) 'stale authority stops action-time reading'
    $fallback = Invoke-Fixture 'read-authority-original.ps1' @('-Path', $old, '-BootstrapFallback')
    Assert-True ($fallback.code -eq 0 -and $fallback.text.Length -gt 32000) 'bootstrap fallback reads changed original in full'
    $built = Invoke-Fixture 'build-authority-digest.ps1'
    Assert-True ($built.code -eq 0 -and ($built.text | ConvertFrom-Json).mode -eq 'digest') 'large inherited authority uses the verified budget path'
    Assert-True (($built.text | ConvertFrom-Json).bootstrap_chars -le 32000) 'digest plus mandatory originals fits the authority bootstrap budget'
    $manifest = Get-Content (Join-Path $root 'authority-digest.json') -Raw | ConvertFrom-Json
    $saved = [IO.File]::ReadAllText($approval)
    Remove-Item -LiteralPath $approval
    $bad = Invoke-Fixture 'verify-authority-digest.ps1'
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_MISSING')) 'missing original fails closed'
    Write-Text $approval $saved
    $manifest.originals = @($manifest.originals | Where-Object { $_.path -ne $old })
    Pin-Manifest $manifest
    $bad = Invoke-Fixture 'verify-authority-digest.ps1'
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_UNCOVERED')) 're-pinned manifest omitting a checkpoint original still fails coverage'
    Invoke-Fixture 'build-authority-digest.ps1' | Out-Null
    [IO.File]::AppendAllText((Join-Path $root 'authority-digest.md'), 'Approved for deploy')
    $bad = Invoke-Fixture 'verify-authority-digest.ps1'
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_DIGEST_HASH')) 'digest content tampering is rejected'
    $manifest = Get-Content (Join-Path $root 'authority-digest.json') -Raw | ConvertFrom-Json
    $manifest.markdown_sha256 = (Get-FileHash (Join-Path $root 'authority-digest.md')).Hash.ToLowerInvariant()
    Pin-Manifest $manifest
    $bad = Invoke-Fixture 'verify-authority-digest.ps1'
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_DIGEST_CONTENT')) 're-pinning a forged digest cannot change the mechanical extracts'
    Invoke-Fixture 'build-authority-digest.ps1' | Out-Null
    [IO.File]::AppendAllText((Join-Path $root 'authority-digest.json'), ' ')
    $bad = Invoke-Fixture 'verify-authority-digest.ps1'
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_MANIFEST_HASH')) 'manifest content is hash pinned'
    Write-Text $old 'Scope: fixtures only.'
    Write-Text (Join-Path $root 'context-wall.json') '{"pre_bootstrap":true}'
    $built = Invoke-Fixture 'build-authority-digest.ps1'
    Assert-True ($built.code -eq 0 -and ($built.text | ConvertFrom-Json).mode -eq 'digest') 'context wall forces digest routing even with a small set'
    $readDigest = Invoke-Fixture 'read-authority-digest.ps1'
    Assert-True ($readDigest.code -eq 0 -and $readDigest.text.Trim() -ceq [IO.File]::ReadAllText((Join-Path $root 'authority-digest.md')).Trim()) 'digest reader emits the verified index in full'
    . (Join-Path $scripts 'context-guard.ps1')
    . (Join-Path $scripts '../hooks/coordinator-pretooluse.ps1')
    Write-Text (Join-Path $root 'context-wall.json') (@{ coordinator_id = 'earlier'; reads = @(@{ path = $old; chars = 50000; reads = 1 }, @{ path = (Join-Path $root 'authority-digest.md'); chars = 50000; reads = 1 }) } | ConvertTo-Json -Depth 4)
    $coordinator = [pscustomobject]@{ run_folder = $root; coordinator_id = 'current' }
    $context = [pscustomobject]@{ state = 'ok'; deferred = $false; line = 'fixture' }
    foreach ($reader in @('read-authority-original.ps1', 'read-authority-digest.ps1')) {
        $pathArgument = if ($reader -eq 'read-authority-original.ps1') { " -Path '$old'" } else { '' }
        $inputRecord = [pscustomobject]@{ tool_name = 'PowerShell'; tool_input = [pscustomobject]@{ command = "pwsh -NoProfile -File '$scripts/$reader' -RunFolder '$root' -BuildStatePath '$checkpoint'$pathArgument" } }
        Assert-True ($null -eq (Get-HookDenyReason -HookInput $inputRecord -Coordinator $coordinator -Context $context)) "$reader remains allowed despite a prior authority wall"
        $context.state = 'rotate'
        Assert-True ($null -ne (Get-HookDenyReason -HookInput $inputRecord -Coordinator $coordinator -Context $context)) "$reader requires handoff at the hard wall"
        $context.state = 'ok'
    }
    Write-Text $current ('Only fixtures. ' * 4000)
    $soft = Invoke-Fixture 'build-authority-digest.ps1'
    $softResult = $soft.text | ConvertFrom-Json
    Assert-True ($soft.code -eq 0 -and $softResult.budget_state -eq 'over_target' -and $softResult.mode -eq 'digest') 'soft-over current authority proceeds with a visible JSON warning'
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'authority-digest.md')).Contains('WARNING: over_target')) 'soft-over Markdown header visibly warns and requires observed transcript confirmation'
    $softRead = Invoke-Fixture 'read-authority-original.ps1' @('-Path', $current)
    Assert-True ($softResult.mandatory_paths -contains $current -and $softRead.code -eq 0 -and $softRead.text.TrimEnd("`r", "`n") -ceq [IO.File]::ReadAllText($current)) 'soft-over never omits or truncates mandatory current authority'
    $manifest = Get-Content (Join-Path $root 'authority-digest.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.budget_chars -eq 32000 -and $manifest.ceiling_chars -eq 96000) 'manifest records both current budget constants'
    foreach ($field in @('budget_chars', 'ceiling_chars')) {
        $savedBudget = $manifest.$field
        $manifest.$field = $savedBudget + 1
        Pin-Manifest $manifest
        $bad = Invoke-Fixture 'verify-authority-digest.ps1'
        Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_MANIFEST_INVALID')) "verifier rejects repinned mismatching $field"
        $manifest.$field = $savedBudget
    }
    Pin-Manifest $manifest
    # Fit the actual emitted index + mandatory originals to exact boundaries.
    # At these sizes inherited navigation extracts are clipped to zero.
    foreach ($limit in @(32000, 32001, 96000, 96001)) {
        Write-Text $current ('x' * $limit)
        $probe = Invoke-Fixture 'build-authority-digest.ps1'
        $mdChars = [IO.File]::ReadAllText((Join-Path $root 'authority-digest.md')).Length
        $pinned = Get-Content (Join-Path $root 'authority-digest.json') -Raw | ConvertFrom-Json
        $otherChars = [IO.File]::ReadAllText($checkpoint).Length
        foreach ($record in $pinned.originals) { if ($record.path -in $pinned.mandatory_paths -and $record.path -ne $current) { $otherChars += $record.chars } }
        Write-Text $current ('x' * ($limit - $mdChars - $otherChars))
        $boundary = Invoke-Fixture 'build-authority-digest.ps1'
        if ($limit -le 96000) {
            $boundaryResult = $boundary.text | ConvertFrom-Json
            $expected = if ($limit -gt 32000) { 'over_target' } else { 'within_target' }
            Assert-True ($boundary.code -eq 0 -and $boundaryResult.bootstrap_chars -eq $limit -and $boundaryResult.budget_state -eq $expected) "exactly $limit chars proceeds with $expected"
            Assert-True ((Invoke-Fixture 'verify-authority-digest.ps1').code -eq 0) "independent verifier accepts exactly $limit chars"
            if ($limit -eq 32000) {
                $savedCheckpoint = [IO.File]::ReadAllText($checkpoint)
                Write-Text $checkpoint ($savedCheckpoint.Replace('last_consumed_event_seq: 7', 'last_consumed_event_seq: 12345'))
                $ownedCross = Invoke-Fixture 'verify-authority-digest.ps1'
                $ownedCrossResult = $ownedCross.text | ConvertFrom-Json
                Assert-True ($ownedCross.code -eq 0 -and $ownedCrossResult.bootstrap_chars -eq 32004 -and $ownedCrossResult.budget_state -eq 'over_target') 'owned cursor crosses soft target without invalidating authority or stopping'
                $ownedRead = Invoke-Fixture 'read-authority-digest.ps1'
                Assert-True ($ownedRead.code -eq 0 -and $ownedRead.text.Contains('WARNING: over_target') -and $ownedRead.text.TrimEnd("`r", "`n").Length -eq ([IO.File]::ReadAllText((Join-Path $root 'authority-digest.md')).TrimEnd("`r", "`n").Length)) 'digest reader renders current warning without adding bootstrap characters'
                Write-Text $checkpoint $savedCheckpoint
            }
        } else {
            Assert-True ($boundary.code -ne 0 -and $boundary.text.Contains('AUTHORITY_BOOTSTRAP_BUDGET') -and $boundary.text.Contains('96001 chars') -and $boundary.text.Contains('consolidate or supersede old stop records')) 'hard-over stops with exact count and actionable operator recovery'
            $bad = Invoke-Fixture 'verify-authority-digest.ps1'
            Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_BOOTSTRAP_BUDGET')) 'independent verifier also stops above hard ceiling'
        }
    }
    $contract = Get-Content (Join-Path $scripts '../references/managed-resume.md') -Raw
    Assert-True ($contract.Contains('32,000 characters') -and $contract.Contains('IN FULL') -and $contract.Contains('Coordinators never author or edit')) 'entry contract names budget, action-time originals and script-only authorship'
    Assert-True ($contract.Contains('## Local work never stops') -and $contract.Contains('Never pin a lifecycle record') -and $contract.Contains('once the action-time read set passes the 32,000-character soft target') -and -not $contract.Contains("Danny's go on that preview")) 'FS-95: local work never stops, lifecycle records are not byte-pinned, rolls run only past the soft target'
    # Reproduce the live failure's scale with 99 fixture originals and a lean checkpoint.
    Write-Text $current "Current boundary: fixtures only. Approval: ``approval.md``"
    $pointers = @('run_status: awaiting_danny', 'last_consumed_event_seq: 7', 'Inherited: `old boundary.md`')
    for ($i = 1; $i -le 95; $i++) {
        $name = "boundary-recovery-$i-operative-source-scope-and-authorization-record.md"
        Write-Text (Join-Path $root $name) ("Scope: fixtures only; never deploy. " + ('operative restriction ' * 200))
        (Get-Item (Join-Path $root $name)).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
        $pointers += "- ``$name``"
    }
    $pointers += 'Current boundary: `current-boundary.md`'
    Write-Text $checkpoint ($pointers -join "`n")
    $built = Invoke-Fixture 'build-authority-digest.ps1'
    $many = Get-Content (Join-Path $root 'authority-digest.json') -Raw | ConvertFrom-Json
    Assert-True ($built.code -eq 0 -and $many.originals.Count -eq 99 -and ($built.text | ConvertFrom-Json).mode -eq 'digest') 'ninety-nine authority originals build and verify without full bootstrap reads'
    Assert-True (($built.text | ConvertFrom-Json).bootstrap_chars -le 32000 -and (Get-Content (Join-Path $root 'authority-digest.md') -Raw).Contains('[clipped]')) 'ninety-nine-source mechanical index remains within bootstrap budget'
    Write-Text $checkpoint (([IO.File]::ReadAllText($checkpoint)).Replace('run_status: awaiting_danny', 'run_status: runnable').Replace('last_consumed_event_seq: 7', 'last_consumed_event_seq: 12345'))
    Assert-True ((Invoke-Fixture 'verify-authority-digest.ps1').code -eq 0) 'ninety-nine-source digest survives the operator resume field changes'
    # Sanitized real checkpoint: spaced absolute aliases, forward alias references,
    # prose glue, sibling filenames, braces and a counted structured inheritance chain.
    . (Join-Path $scripts 'authority-digest.ps1')
    $liveRoot = Join-Path $root 'live shape with spaces'
    New-Item -ItemType Directory -Path $liveRoot | Out-Null
    $liveCheckpoint = Join-Path $liveRoot '_build-state.md'
    $fixtureShape = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/authority-checkpoint-compressed.md')).Replace('__RUN__', $liveRoot.Replace('\', '/'))
    Write-Text $liveCheckpoint $fixtureShape
    $baseDirectory = Join-Path $liveRoot 'milestones/M05/base/local-stop-base'
    $parentDirectory = Join-Path $liveRoot 'milestones/M05/parent-work/local-stop-parent'
    $stopDirectory = Join-Path $liveRoot 'milestones/M05/parent-work/local-stop-current'
    $workDirectory = Join-Path $liveRoot 'milestones/M05/current-work'
    foreach ($directory in @($baseDirectory, $parentDirectory, $stopDirectory, $workDirectory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $baseOriginals = @()
    for ($i = 1; $i -le 87; $i++) {
        $original = Join-Path $baseDirectory "inherited-$i.md"
        Write-Text $original ("Only fixture authority. Never deploy.`n" + ('inherited history ' * 500))
        $baseOriginals += $original
    }
    function Write-Stop([string]$Directory, [int]$Count, [string]$InheritedBoundary, [string[]]$InheritedSources = @()) {
        foreach ($name in @('source-disposition.json', 'next-scope.md', 'next-approval.md')) { Write-Text (Join-Path $Directory $name) 'Only fixture authority; no deployment.' }
        $boundary = [ordered]@{ scope = (Join-Path $Directory 'next-scope.md'); source_disposition = (Join-Path $Directory 'source-disposition.json'); approval_text = (Join-Path $Directory 'next-approval.md'); required_original_records = $Count; original_inherited_record_count = ($Count - 4) }
        if ($InheritedBoundary) { $boundary.inherited_boundary = $InheritedBoundary } else { $boundary.inherited_authority_sources = $InheritedSources }
        Write-Text (Join-Path $Directory 'next-operation-boundary.json') ($boundary | ConvertTo-Json -Depth 5)
    }
    Write-Stop $baseDirectory 91 '' $baseOriginals
    Write-Stop $parentDirectory 95 (Join-Path $baseDirectory 'next-operation-boundary.json')
    Write-Stop $stopDirectory 99 (Join-Path $parentDirectory 'next-operation-boundary.json')
    foreach ($name in @('approvals.json', 'operator-notes.json', 'build-state.md', 'build-plan.md')) { Write-Text (Join-Path $liveRoot $name) 'Only fixture authority.' }
    foreach ($name in @('coordinator-metadata-disposition.md', 'coordinator-full-failure-disposition.md', 'coordinator-notes-locator-disposition.md', 'coordinator-report-path-metadata-disposition.md')) { Write-Text (Join-Path (Split-Path $stopDirectory -Parent) $name) 'Metadata clarification; grants no authority.' }
    foreach ($name in @('vendor-capacity-stop.md', 'session-audit.md')) { Write-Text (Join-Path $workDirectory $name) 'Current stop: no redispatch.' }
    $dryOutput = Join-Path $root 'external dryrun output'
    function Invoke-LiveShape([string]$Script, [string[]]$Extra = @()) {
        $raw = & pwsh -NoProfile -File (Join-Path $scripts $Script) -RunFolder $liveRoot -BuildStatePath $liveCheckpoint @Extra 2>&1
        return [pscustomobject]@{ code = $LASTEXITCODE; text = ($raw -join "`n") }
    }
    $built = Invoke-LiveShape 'build-authority-digest.ps1' @('-DryRun', '-OutputDirectory', $dryOutput)
    Assert-True ($built.code -eq 0) 'sanitized compressed live checkpoint builds externally in DryRun'
    $liveManifest = Get-Content (Join-Path $dryOutput 'authority-digest.json') -Raw | ConvertFrom-Json
    $liveResult = $built.text | ConvertFrom-Json
    Assert-True ($liveManifest.enumerated_paths.Count -eq 99 -and $liveManifest.originals.Count -eq 109) 'structured chain covers STOP four plus inherited ninety-five and ten supplements exactly'
    Assert-True (-not (Test-Path (Join-Path $liveRoot 'authority-digest.json')) -and -not (Test-Path (Join-Path $liveRoot 'authority-digest.md'))) 'DryRun writes neither digest nor pin in source run'
    Assert-True ($liveResult.unresolved_candidates.Count -eq 1 -and $liveResult.unresolved_candidates[0].candidate -eq 'WORK/absent-evidence.md' -and -not $liveResult.unresolved_candidates[0].required) 'non-authority absent evidence is reported without failing the build'
    Assert-True (([IO.File]::ReadAllText((Join-Path $dryOutput 'authority-digest.md'))).Contains('WORK/absent-evidence.md')) 'Markdown diagnostics retains every unresolved non-authority candidate'
    Assert-True ($liveManifest.originals.path -contains (Join-Path $liveRoot 'operator-notes.json')) 'glued solelyRUN resolves to the real standing notes'
    Assert-True (@($liveManifest.originals | Where-Object { $_.path -like '*coordinator-*-disposition.md' }).Count -eq 4) 'directory-inherited comma siblings resolve all four metadata records'
    Assert-True ($liveResult.bootstrap_chars -le 32000 -and $liveResult.deferred_original_bytes -gt 700000) 'compressed path table fits budget while retaining large inherited originals'
    $aliases = Get-AuthorityAliases $fixtureShape
    Assert-True ((Resolve-AuthorityLiteral 'PARENT/record.md' $liveCheckpoint $liveRoot $aliases) -eq (Join-Path $liveRoot 'milestones/M05/parent-work/successor-3/record.md')) 'forward alias references resolve recursively with spaces preserved'
    Assert-True ((Resolve-AuthorityLiteral 'SPACED/record.md' $liveCheckpoint $liveRoot $aliases) -eq (Join-Path $liveRoot 'milestones/M05/parent-work/folder with spaces/record.md')) 'relative alias values retain embedded spaces to end of their list item'
    $brace = @(Get-AuthorityCandidates $fixtureShape $aliases | Where-Object literal -like 'RUN/milestones/M05/base/local-stop-base/*')
    Assert-True ($brace.Count -eq 4) 'brace list expands to four distinct known-alias file paths'
    Assert-True ((Invoke-LiveShape 'verify-authority-digest.ps1' @('-DigestDirectory', $dryOutput)).code -eq 0) 'verifier accepts the external digest location'
    # Independently decode the published navigation notation to prove it loses no paths.
    $decodedDirectories = @{}; $decodedFiles = @{}; $decodedPaths = @(); $pathPrefix = ''
    foreach ($line in ([IO.File]::ReadAllText((Join-Path $dryOutput 'authority-digest.md')) -split '\n')) {
        if ($line -match '^P=(.*)$') { $pathPrefix = $Matches[1] }
        elseif ($line -match '^(D\d+)=(.*)$') {
            $name = $Matches[1]; $value = $Matches[2]
            if ($value -match '^(D\d+)\[:(\d+)\](.*)$') { $value = $decodedDirectories[$Matches[1]].Substring(0, [int]$Matches[2]) + $Matches[3] }
            elseif ($value.StartsWith('P/')) { $value = $pathPrefix + '/' + $value.Substring(2) }
            $decodedDirectories[$name] = $value
        } elseif ($line -match '^(F\d+)=(.*)$') { $decodedFiles[$Matches[1]] = $Matches[2] }
        elseif ($line -match '^(D\d+):(F\d+(?:,F\d+)*)$') {
            $directory = $decodedDirectories[$Matches[1]]
            foreach ($member in ($Matches[2] -split ',')) { $decodedPaths += [IO.Path]::GetFullPath((Join-Path $liveRoot (Join-Path $directory $decodedFiles[$member]))) }
        }
    }
    Assert-True (($decodedPaths | Sort-Object) -join "`n" -ceq (($liveManifest.originals.path | Sort-Object) -join "`n")) 'independent Markdown path decoder reconstructs all 109 manifest originals exactly'
    $liveManifest.diagnostics = @()
    Write-Text (Join-Path $dryOutput 'authority-digest.json') ($liveManifest | ConvertTo-Json -Depth 8)
    Write-Text (Join-Path $dryOutput 'authority-digest.json.sha256') (Get-FileHash (Join-Path $dryOutput 'authority-digest.json')).Hash.ToLowerInvariant()
    $bad = Invoke-LiveShape 'verify-authority-digest.ps1' @('-DigestDirectory', $dryOutput)
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_DISCOVERY')) 'repinning cannot conceal an unresolved candidate diagnostic'
    $bad = Invoke-LiveShape 'build-authority-digest.ps1' @('-DryRun')
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_DRYRUN_OUTPUT')) 'DryRun requires an explicit external destination'
    $bad = Invoke-LiveShape 'build-authority-digest.ps1' @('-DryRun', '-OutputDirectory', (Join-Path $liveRoot 'output'))
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_DRYRUN_OUTPUT') -and -not (Test-Path (Join-Path $liveRoot 'output'))) 'DryRun rejects writes anywhere under the source run'
    $redirect = Join-Path $root 'external junction into live source'
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $redirect -Target $liveRoot | Out-Null
    try {
        $bad = Invoke-LiveShape 'build-authority-digest.ps1' @('-DryRun', '-OutputDirectory', (Join-Path $redirect 'output'))
        Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_DRYRUN_OUTPUT') -and -not (Test-Path (Join-Path $liveRoot 'output'))) 'DryRun resolves junctions before rejecting disguised source-run output'
    } finally { (Get-Item -LiteralPath $redirect -Force).Delete() }
    Remove-Item -LiteralPath (Join-Path $liveRoot 'approvals.json')
    $bad = Invoke-LiveShape 'build-authority-digest.ps1' @('-DryRun', '-OutputDirectory', $dryOutput)
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_MISSING') -and $bad.text.Contains('approvals.json')) 'missing mandatory current approvals fail closed even without a literal checkpoint locator'
    Write-Text (Join-Path $liveRoot 'approvals.json') 'Only fixture authority.'
    Write-Text $liveCheckpoint ($fixtureShape + "`n- Beforebootstrap read WORK/missing-authority.md IN FULL.")
    Remove-Item -LiteralPath $baseOriginals[0], $baseOriginals[1]
    $bad = Invoke-LiveShape 'build-authority-digest.ps1' @('-DryRun', '-OutputDirectory', $dryOutput)
    $failureDiagnostics = Get-Content (Join-Path $dryOutput 'authority-diagnostics.json') -Raw | ConvertFrom-Json
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_MISSING')) 'missing enumerated or checkpoint-required originals fail closed'
    Assert-True (@($failureDiagnostics | Where-Object required).Count -eq 3) 'failure diagnostics reports both missing inherited originals and the missing named current original'
    Write-Text $liveCheckpoint $fixtureShape
    foreach ($original in $baseOriginals[0..1]) { Write-Text $original 'Only fixture authority.' }
    $boundaryJson = Get-Content (Join-Path $stopDirectory 'next-operation-boundary.json') -Raw | ConvertFrom-Json
    $boundaryJson.required_original_records = 98
    Write-Text (Join-Path $stopDirectory 'next-operation-boundary.json') ($boundaryJson | ConvertTo-Json -Depth 5)
    $bad = Invoke-LiveShape 'build-authority-digest.ps1' @('-DryRun', '-OutputDirectory', $dryOutput)
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_ENUMERATION_COUNT')) 'declared source-count mismatch fails closed'
    $cyclicAliases = @{ A = 'B/root'; B = 'A/root' }
    $cycleFailed = $false
    try { Resolve-AuthorityLiteral 'A/record.md' $liveCheckpoint $liveRoot $cyclicAliases | Out-Null } catch { $cycleFailed = $_.Exception.Message.Contains('AUTHORITY_ALIAS_CYCLE') }
    Assert-True $cycleFailed 'cyclic alias definitions fail closed without an unbounded resolver loop'
    # FS-111: prose locators are diagnostics; a genuinely named missing original still stops.
    $proseRoot = Join-Path $root 'prose-tokens'
    New-Item -ItemType Directory -Path $proseRoot | Out-Null
    $proseCheckpoint = Join-Path $proseRoot '_build-state.md'
    Write-Text $proseCheckpoint 'Scope: fixtures only.'
    $tokens = @(
        'D:\Claude\sessions\*.json',
        'skills\dt-roadmap\references\roadmap-schema.md',
        '~\.codex\sessions\YYYY\MM\DD\rollout-*.jsonl',
        '00_Resources\ops-conventions.md',
        'raw\<machine>\<tool>\<session_id>.jsonl',
        'digests\<machine>\<workstation>\<YYYY-MM-DD>_<session_id>.md'
    )
    $missingOriginal = Join-Path $proseRoot 'genuinely-missing-original.md'
    Write-Text (Join-Path $proseRoot 'operator-notes.json') (@{ notes = @($tokens) + @($missingOriginal) } | ConvertTo-Json)
    $missingFailure = ''
    try { Get-AuthorityInventory $proseRoot $proseCheckpoint | Out-Null } catch { $missingFailure = $_.Exception.Message }
    Assert-True ($missingFailure.StartsWith('AUTHORITY_MISSING:') -and $missingFailure.Contains($missingOriginal)) 'prose tokens do not mask a missing absolute named original'
    foreach ($token in $tokens) {
        $skipped = @($script:AuthorityDiagnostics | Where-Object { $_.candidate -ceq $token -and $_.reason -eq 'non_authority_reference' -and -not $_.required })
        Assert-True ($skipped.Count -eq 1) "prose token skipped exactly once: $token"
    }
    Assert-True (@($script:AuthorityDiagnostics | Where-Object required).Count -eq 1) 'only the genuinely missing absolute original is required'
    Write-Text $missingOriginal 'Only fixture authority.'
    $inventory = @(Get-AuthorityInventory $proseRoot $proseCheckpoint)
    Assert-True ($inventory.Count -eq 2) 'six prose tokens permit inventory once the genuine original exists'
    New-Item -ItemType Directory -Path (Join-Path $proseRoot 'approvals') | Out-Null
    Write-Text (Join-Path $proseRoot 'operator-notes.json') '{"source":"approvals/missing.md"}'
    $missingFailure = ''
    try { Get-AuthorityInventory $proseRoot $proseCheckpoint | Out-Null } catch { $missingFailure = $_.Exception.Message }
    Assert-True ($missingFailure.StartsWith('AUTHORITY_MISSING:') -and $missingFailure.Contains('missing.md')) 'missing source-relative original under a real directory fails closed'
    # FS-123: bare artifact names in prose (files the build will create) are not named originals.
    $bareNames = @('index.json', 'requirements-dev.txt', 'open-sessions.json')
    $designDoc = Join-Path $proseRoot 'design-final-fixture.md'
    Write-Text $designDoc ("The hub writes " + (($bareNames | ForEach-Object { "``$_``" }) -join ', ') + '.')
    Write-Text (Join-Path $proseRoot 'operator-notes.json') (@{ design = $designDoc } | ConvertTo-Json)
    $bareInventory = @(Get-AuthorityInventory $proseRoot $proseCheckpoint)
    Assert-True ($bareInventory.Count -ge 1) 'missing bare artifact names in a design document do not block the inventory'
    foreach ($name in $bareNames) {
        $bare = @($script:AuthorityDiagnostics | Where-Object { $_.candidate -ceq $name -and $_.reason -eq 'non_authority_reference' -and -not $_.required })
        Assert-True ($bare.Count -eq 1) "bare artifact name in a design document skipped as non-authority: $name"
    }
    # FS-132: milestone briefs naming bare artifacts are not originals.
    $briefDir = Join-Path $proseRoot 'milestones/M06'
    New-Item -ItemType Directory -Path $briefDir -Force | Out-Null
    $brief = Join-Path $briefDir 'fix-brief-3.md'
    Write-Text $brief 'The verifier writes `verify-sources-progress.json`.'
    Write-Text (Join-Path $proseRoot 'operator-notes.json') (@{ brief = $brief } | ConvertTo-Json)
    $briefInventory = @(Get-AuthorityInventory $proseRoot $proseCheckpoint)
    Assert-True ($briefInventory.Count -ge 1 -and @($script:AuthorityDiagnostics | Where-Object { $_.candidate -ceq 'verify-sources-progress.json' -and -not $_.required }).Count -eq 1) 'bare artifact name in a milestone brief is not a named original'
    # FS-132: an absolute path does not run across another file's extension into later prose.
    $spanned = @(Get-AuthorityCandidates 'Errors go to D:\State Dir\errors.log). Detail: build-decision-log.md' @{})
    Assert-True (@($spanned | Where-Object { $_.literal -match 'errors\.log\)' }).Count -eq 0) 'absolute path candidate stops at another extension instead of spanning prose'
    $spaced = @(Get-AuthorityCandidates 'Read D:\Claude\Home Server\design\_build-state.md now.' @{})
    Assert-True (@($spaced | Where-Object { $_.literal -ceq 'D:\Claude\Home Server\design\_build-state.md' }).Count -eq 1) 'absolute paths with spaces still resolve whole'
    Write-Text (Join-Path $proseRoot 'operator-notes.json') '{"source":"missing-bare-approval.md"}'
    $missingFailure = ''
    try { Get-AuthorityInventory $proseRoot $proseCheckpoint | Out-Null } catch { $missingFailure = $_.Exception.Message }
    Assert-True ($missingFailure.StartsWith('AUTHORITY_MISSING:') -and $missingFailure.Contains('missing-bare-approval.md')) 'missing bare name outside a design document still fails closed'
    Write-Output "SUMMARY: $script:passed passed"
}
finally {
    foreach ($identity in $operatorEnvironment.Keys) { [Environment]::SetEnvironmentVariable($identity, $operatorEnvironment[$identity], 'Process') }
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
