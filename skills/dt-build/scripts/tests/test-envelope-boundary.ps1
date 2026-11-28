param([string]$DtJobPath = (Join-Path $PSScriptRoot '../dt-job.ps1'), [int]$Repeats = 10, [switch]$ObserveOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../../scripts/lib/runtime-test-admission.ps1')
Enter-RuntimeTestSuite
. (Join-Path $PSScriptRoot 'test-shell.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('envelope-boundary-' + [guid]::NewGuid().ToString('N'))
$env:DT_BUILD_STATE_DIR = Join-Path $root 'registry'
$env:DT_BUILD_HEADLESS = '1'
$run = Join-Path $root 'run'
New-Item -ItemType Directory $run -Force | Out-Null
function Job([string[]]$Arguments) {
    $r = Invoke-TestShell -File $DtJobPath -Arguments ($Arguments + @('-AllowTempRunFolder','-Json'))
    if ($r.ExitCode) { throw $r.ErrorText }
    return ($r.Output -join "`n" | ConvertFrom-Json)
}
$failures = 0
try {
    $job = Job @('start','-RunFolder',$run,'-Command',"'fixture complete'")
    $null = Job @('wait','-RunFolder',$run,'-JobId',$job.job_id,'-TimeoutSec','60')
    $record = Get-Content -Raw $job.job_file | ConvertFrom-Json
    if ($record.status -ne 'succeeded') { throw 'Envelope seed did not succeed' }
    $ids = @(1..300 | ForEach-Object { 'j-{0:D4}' -f $_ })
    foreach ($id in $ids) {
        $record.job_id = $id
        [IO.File]::WriteAllText((Join-Path $run "jobs/$id.json"), ($record | ConvertTo-Json -Depth 12))
    }
    foreach ($repeat in 1..$Repeats) {
        # Exercise the narrow remainder at the cap, not only identical lengths.
        # These are fixture-owned standing notes; no operator command is bypassed.
        [IO.File]::WriteAllText((Join-Path $run 'operator-notes.json'), (@{ notes=@(@{id='n-boundary';text=('x' * ($repeat * 15))}) } | ConvertTo-Json -Depth 4))
        foreach ($verb in @('status','wait')) {
            $arguments = @($verb,'-RunFolder',$run)
            if ($verb -eq 'wait') { $arguments += @('-JobId',($ids -join ','),'-All','-TimeoutSec','1') }
            $reply = Job $arguments
            $bytes = [Text.Encoding]::UTF8.GetByteCount(($reply | ConvertTo-Json -Depth 8 -Compress))
            $ok = $reply.truncated -and @($reply.jobs).Count -lt 300 -and $bytes -le 8192
            if (-not $ok) { $failures++ }
            "ENVELOPE repeat=$repeat verb=$verb bytes=$bytes jobs=$(@($reply.jobs).Count) pass=$ok"
        }
    }
    "SUMMARY: $($Repeats * 2) observations; $failures oversized/invalid envelopes; source=$DtJobPath"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
if ($failures -and -not $ObserveOnly) { exit 1 }
