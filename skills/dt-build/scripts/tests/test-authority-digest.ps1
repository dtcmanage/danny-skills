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
    $bad = Invoke-Fixture 'build-authority-digest.ps1'
    Assert-True ($bad.code -ne 0 -and $bad.text.Contains('AUTHORITY_BOOTSTRAP_BUDGET')) 'oversized current authority cannot be silently omitted'
    $contract = Get-Content (Join-Path $scripts '../references/managed-resume.md') -Raw
    Assert-True ($contract.Contains('32,000 characters') -and $contract.Contains('IN FULL') -and $contract.Contains('Coordinators never author or edit')) 'entry contract names budget, action-time originals and script-only authorship'
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
    Write-Output "SUMMARY: $script:passed passed"
}
finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
