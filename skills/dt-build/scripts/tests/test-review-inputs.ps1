#Requires -Version 7.0
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }
    $script:passed++
}
function Assert-Refused([scriptblock]$Action, [string]$Reason) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -and $failure.Contains($Reason)) "expected $Reason; got $failure"
}
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'review-inputs.ps1')
. (Join-Path $scripts 'dt-job.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('dt-review-inputs-' + [guid]::NewGuid().ToString('N'))
$registryBefore = $env:DT_BUILD_STATE_DIR
$coordinatorBefore = $env:DT_BUILD_COORDINATOR_ID
$jobBefore = $env:DT_JOB_ID
try {
    $null = [IO.Directory]::CreateDirectory($temp)
    $env:DT_BUILD_STATE_DIR = Join-Path $temp 'registry'
    $env:DT_BUILD_COORDINATOR_ID = $null; $env:DT_JOB_ID = $null
    $run = Join-Path $temp 'run'
    $null = [IO.Directory]::CreateDirectory($run)
    $notes = Join-Path $run 'operator-notes.json'
    $guide = Join-Path $temp 'ops-guide.md'
    $source = Join-Path $temp 'source.py'
    $authority = Join-Path $temp 'boundary.md'
    $approvals = Join-Path $run 'approvals.json'
    $predecessor = Join-Path $temp 'predecessor.json'
    $appendNotes = Join-Path $temp 'notes.jsonl'
    [IO.File]::WriteAllText($notes, '{"notes":[{"id":"n-001","text":"first","added_utc":"2026-10-12T00:00:00Z"}]}')
    [IO.File]::WriteAllText($guide, 'operator steps')
    [IO.File]::WriteAllText($source, 'print(1)')
    [IO.File]::WriteAllText($authority, 'source only')
    [IO.File]::WriteAllText($approvals, '{"approvals":[]}')
    [IO.File]::WriteAllText($predecessor, '{"pass":true}')
    [IO.File]::WriteAllText($appendNotes, "one`ntwo`n")
    Assert-True (Test-DtPathEqual $run.Replace('\', '/') ($run.Replace('/', '\') + '\')) 'slash forms and trailing separators match'
    if ([OperatingSystem]::IsWindows()) {
        Assert-True (Test-DtPathEqual $run.ToUpperInvariant() $run.ToLowerInvariant()) 'Windows paths ignore case'
        Assert-True ((ConvertTo-DtPathIdentity 'C:/') -ceq 'c:\') 'drive root remains absolute'
        Assert-True (Test-DtPathEqual '\\server\share\dir\' '//SERVER/share/dir') 'UNC identity preserves share and accepts either slash'
    } else {
        Assert-True (-not (Test-DtPathEqual '/tmp/File' '/tmp/file')) 'non-Windows paths preserve case'
        Assert-True ((ConvertTo-DtPathIdentity '/') -ceq '/') 'filesystem root preserved'
    }
    Assert-True (-not (Test-DtPathEqual $guide $source)) 'different inputs do not match'
    $manifestPath = Join-Path $temp 'inputs.json'
    $manifest = @{ inputs = @(
        @{ path = $notes.Replace('\', '/'); kind = 'operator-notes' },
        @{ path = $guide; kind = 'ops-guide' },
        @{ path = $source; kind = 'source' },
        @{ path = $authority; kind = 'authority' },
        @{ path = $approvals; kind = 'approvals' },
        @{ path = $predecessor; kind = 'predecessor-evidence' },
        @{ path = $appendNotes; kind = 'append-only-notes' }
    ) }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10))
    $directory = Join-Path $temp 'packet'
    $prepJson = & pwsh -NoProfile -File (Join-Path $scripts 'prepare-review-packet.ps1') -InputManifestPath $manifestPath -PacketDirectory $directory
    Assert-True ($LASTEXITCODE -eq 0) 'prep CLI succeeds'
    $prep = ($prepJson -join "`n") | ConvertFrom-Json
    $verify = { Test-DtReviewPacket $prep.packet_path $prep.packet_sha256 }
    $initial = & $verify
    Assert-True ($initial.pass -and $initial.changes.Count -eq 0 -and $initial.checked_inputs -eq 7) 'initial pins all match'
    $alternate = [IO.File]::ReadAllText($prep.packet_path) | ConvertFrom-Json -AsHashtable
    foreach ($item in $alternate.inputs) {
        $item.path = $item.path.Replace('\', '/')
        $item.review_path = $item.review_path.Replace('\', '/')
        if ([OperatingSystem]::IsWindows()) { $item.path = $item.path.ToUpperInvariant(); $item.review_path = $item.review_path.ToUpperInvariant() }
    }
    $alternatePath = Join-Path $directory 'alternate-paths.json'
    [IO.File]::WriteAllText($alternatePath, ($alternate | ConvertTo-Json -Depth 20))
    Assert-True (Test-DtReviewPacket $alternatePath (Get-DtReviewDigest ([IO.File]::ReadAllBytes($alternatePath)))).pass 'packet accepts forward slash records and Windows case without changing byte pins'
    $notesSnapshot = $prep.inputs[0].review_path
    $snapshotOriginal = [IO.File]::ReadAllText($notesSnapshot)
    Assert-True ($notesSnapshot -cne $notes -and $snapshotOriginal -ceq [IO.File]::ReadAllText($notes)) 'notes copied byte-for-byte into packet'
    & pwsh -NoProfile -File (Join-Path $scripts 'dt-job.ps1') note -RunFolder $run -Message 'second' -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'real dt-job note appends after prep'
    $after = & $verify
    Assert-True ($after.pass -and $after.changes.Count -eq 1 -and $after.changes[0].new_entries -eq 1 -and $after.changes[0].removed_entries -eq 0 -and $after.changes[0].message.Contains('notes changed since review prep: 1 new entries')) 'one new note is information, not pin failure'
    Assert-True ([IO.File]::ReadAllText($notesSnapshot) -ceq $snapshotOriginal) 'live note update leaves review snapshot untouched'
    [IO.File]::AppendAllText($guide, ' clarification')
    [IO.File]::AppendAllText($appendNotes, "two`nthree`n")
    $after = & $verify
    Assert-True ($after.pass -and @($after.changes | Where-Object kind -eq 'ops-guide')[0].message -eq 'guide changed since review prep') 'edited guide reported without failure'
    Assert-True (@($after.changes | Where-Object kind -eq 'append-only-notes')[0].new_entries -eq 2) 'append-only notes count duplicate additions'
    $verifyJson = & pwsh -NoProfile -File (Join-Path $scripts 'verify-review-packet.ps1') -PacketPath $prep.packet_path -ExpectedPacketSha256 $prep.packet_sha256
    Assert-True ($LASTEXITCODE -eq 0 -and (($verifyJson -join "`n") | ConvertFrom-Json).changes.Count -eq 3) 'verify CLI surfaces mutable changes'
    foreach ($immutable in @($source, $authority, $approvals, $predecessor)) {
        $original = [IO.File]::ReadAllBytes($immutable)
        [IO.File]::AppendAllText($immutable, ' drift')
        Assert-Refused $verify 'REVIEW_INPUT_HASH_DRIFT'
        [IO.File]::WriteAllBytes($immutable, $original)
    }
    [IO.File]::AppendAllText($notesSnapshot, ' corruption')
    Assert-Refused $verify 'REVIEW_INPUT_HASH_DRIFT'
    [IO.File]::WriteAllText($notesSnapshot, $snapshotOriginal)
    Assert-Refused { Test-DtReviewPacket $prep.packet_path ('0' * 64) } 'REVIEW_PACKET_HASH_DRIFT'
    Assert-Refused { New-DtReviewPacket $manifestPath $directory } 'REVIEW_PACKET_EXISTS'
    Assert-Refused { Get-DtReviewInputFormat 'operator-notes' $approvals } 'REVIEW_INPUT_KIND_PATH'
    Assert-Refused { Get-DtReviewInputFormat 'ops-guide' $source } 'REVIEW_INPUT_KIND_PATH'
    Assert-True ((Get-DtReviewInputFormat 'authority' $guide) -eq 'immutable') 'a guide used as authority remains immutable'
    Assert-Refused { Get-DtReviewInputFormat 'generic-mutable' $guide } 'REVIEW_INPUT_KIND'
    [IO.File]::WriteAllText($notes, '{malformed')
    Assert-True (@((& $verify).changes | Where-Object kind -eq 'operator-notes')[0].message.Contains('unreadable')) 'malformed live notes surfaced without relaxing snapshot pin'
    Remove-Item -LiteralPath $guide
    Assert-True (@((& $verify).changes | Where-Object kind -eq 'ops-guide')[0].message.Contains('unavailable')) 'removed live guide surfaced without failure'
    [IO.File]::WriteAllText($guide, 'changed guide')
    # Legacy registry/read records also accept the alternate recorded spelling.
    Save-DtJobRegistryRuns -Runs @([pscustomobject]@{ run_folder = $run.Replace('\', '/') + '/'; run_id = 'fixture' })
    Assert-True ((Get-DtJobRegistryEntry $run).run_id -eq 'fixture') 'legacy registry paths compare after normalization'
    $jobs = Join-Path $run 'jobs'; $null = [IO.Directory]::CreateDirectory($jobs)
    $readLog = Join-Path $jobs 'reads.jsonl'
    $priorRead = @{ path = $guide.Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $guide).Hash.ToLowerInvariant(); selector = [ordered]@{ mode = 'lines'; range = '1-1' } }
    [IO.File]::WriteAllText($readLog, ($priorRead | ConvertTo-Json -Compress -Depth 5) + "`n")
    $readJson = & pwsh -NoProfile -File (Join-Path $scripts 'read-evidence.ps1') -RunFolder $run -Path $guide -Lines 1-1 -Json
    Assert-True ($LASTEXITCODE -eq 0 -and (($readJson -join "`n") | ConvertFrom-Json).warnings.Count -eq 1) 'read-evidence normalizes legacy recorded slash form'
    Write-Output "PASS: review inputs; SUMMARY: $script:passed passed"
} finally {
    $env:DT_BUILD_STATE_DIR = $registryBefore
    $env:DT_BUILD_COORDINATOR_ID = $coordinatorBefore; $env:DT_JOB_ID = $jobBefore
    if ($temp -and [IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
