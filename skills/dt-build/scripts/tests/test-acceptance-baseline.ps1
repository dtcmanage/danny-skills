#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../acceptance-baseline.ps1')
$root = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.cache/build-acceptance-gates/floor-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
function Check([bool]$Ok, [string]$Label) { if (-not $Ok) { throw $Label }; "PASS: $Label" }
function Result([string]$Name, [string]$Text, [int]$ExitCode=1, [bool]$Timeout=$false) {
    $out = Join-Path $root "$Name.out"; $err = Join-Path $root "$Name.err"
    [IO.File]::WriteAllText($out, $Text); [IO.File]::WriteAllText($err, '')
    [pscustomobject]@{ stdout_path=$out; stderr_path=$err; exit_code=$ExitCode; timed_out=$Timeout }
}
try {
    $a = Result a "/feature/tests/test_x.py: assertion failed`n$('same tail' * 1000)"
    $b = Result b "/main/tests/test_x.py: assertion failed`n$('same tail' * 1000)"
    Check (Test-AcceptanceBaselineFailure $a $b /feature /main) 'identical complete failure with source roots normalized passes'
    $c = Result c "/feature/tests/test_x.py: NEW failure`n$('same tail' * 1000)"
    Check (-not (Test-AcceptanceBaselineFailure $c $b /feature /main)) 'changed failure outside retained tail blocks'
    $c = Result c "/feature/tests/test_x.py: assertion failed`n$('same tail' * 1000)`nNEW failure"
    Check (-not (Test-AcceptanceBaselineFailure $c $b /feature /main)) 'additional failure blocks'
    $c = Result c same 0
    Check (-not (Test-AcceptanceBaselineFailure $a $c /feature /main)) 'successful main cannot waive a failure'
    $a.timed_out = $true
    Check (-not (Test-AcceptanceBaselineFailure $a $b /feature /main)) 'timeout never establishes the floor'
    $a.timed_out = $false; $b.exit_code = 2
    Check (-not (Test-AcceptanceBaselineFailure $a $b /feature /main)) 'changed exit code blocks'
    foreach ($code in @(124,126,127,137,139,143)) {
        $x = Result x 'same failure' $code; $y = Result y 'same failure' $code
        Check (-not (Test-AcceptanceBaselineFailure $x $y /feature /main)) "infrastructure exit $code blocks identical failures"
    }
    foreach ($errorText in @('No module named pytest', 'ModuleNotFoundError: pytest', 'ImportError: cannot import runner', 'bash: pytest: command not found', 'pytest is not recognized as a command', 'error while loading shared libraries: libpython.so', 'bad interpreter: No such file', 'Cannot find module vitest', 'Could not load file or assembly runner', 'Permission denied', 'ERROR at setup of test_x', 'ERROR collecting test_x.py', 'Interrupted: 1 error during collection', 'no tests ran', 'ERROR: usage: pytest')) {
        $x = Result x $errorText; $y = Result y $errorText
        Check (-not (Test-AcceptanceBaselineFailure $x $y /feature /main)) "infrastructure diagnostic blocks: $errorText"
    }
    $a = Result a '/feature/tests/x.py: assertion failed'; $b = Result b '/main/tests/x.py: assertion failed'
    $receipt = [pscustomobject]@{
        available=$true; identical_failure=$true; commit=('a'*40); note='known failing test'
        current_source_root='/feature'; baseline_source_root='/main'; result=$b
        current_fingerprint=(Get-AcceptanceFailureFingerprint $a /feature)
        baseline_fingerprint=(Get-AcceptanceFailureFingerprint $b /main)
    }
    $a | Add-Member baseline $receipt
    Check (Test-AcceptanceCommandPass $a) 'saved pass recomputes both full stream fingerprints'
    $saved = $receipt.current_fingerprint
    $receipt.current_fingerprint = '0'*64; $receipt.baseline_fingerprint = '0'*64
    Check (-not (Test-AcceptanceCommandPass $a)) 'matching fabricated fingerprint fields refused'
    $receipt.current_fingerprint = $saved; $receipt.baseline_fingerprint = $saved
    [IO.File]::AppendAllText($b.stderr_path, 'changed evidence')
    Check (-not (Test-AcceptanceCommandPass $a)) 'changed retained stderr refused'
    [IO.File]::WriteAllText($b.stderr_path, '')
    [IO.File]::AppendAllText($a.stdout_path, 'changed evidence')
    Check (-not (Test-AcceptanceCommandPass $a)) 'changed retained stdout refused'
    Remove-Item $a.stdout_path
    Check (-not (Test-AcceptanceCommandPass $a)) 'missing retained stream refused'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
