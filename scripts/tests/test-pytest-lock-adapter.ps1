# Windows PowerShell-only argv fixtures. python is shadowed by a checked .ps1
# shim in the child PATH. No Python, pytest or lock/guard driver is started.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This fixture checks Windows PowerShell command resolution.' }
$adapter = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../pytest-lock.ps1'))
$pwsh = (Get-Command pwsh -CommandType Application).Source
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('fs58-adapter-' + [guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH
$savedCapture = $env:FS58_ARGV_CAPTURE
$savedExit = $env:FS58_CHILD_EXIT
$passed = 0
function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw "ASSERT_FAIL: $message" }
    $script:passed++
}
function Read-Argv {
    return ,@(Get-Content -LiteralPath $env:FS58_ARGV_CAPTURE -Raw | ConvertFrom-Json)
}
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $shim = Join-Path $fixture 'python.ps1'
    [IO.File]::WriteAllText($shim, @'
param()
[IO.File]::WriteAllText($env:FS58_ARGV_CAPTURE, (ConvertTo-Json -InputObject @($args) -Depth 8))
if (@($args | Where-Object { $_ -is [array] }).Count) { exit 1 }
exit ([int]$env:FS58_CHILD_EXIT)
'@)
    $env:PATH = $fixture + [IO.Path]::PathSeparator + $savedPath
    $env:FS58_ARGV_CAPTURE = Join-Path $fixture 'argv.json'
    $env:FS58_CHILD_EXIT = '0'
    Assert-True ((Get-Command python).Source -eq $shim) 'python resolves to the PowerShell shim'
    # Confirm resolution in a new interpreter before invoking the product script.
    $resolvedChild = & $pwsh -NoProfile -Command '(Get-Command python).Source'
    Assert-True ($LASTEXITCODE -eq 0 -and $resolvedChild -eq $shim) 'child also resolves python to the shim'

    # Retain the original CommandWithArgs wrapper verbatim. An array expression
    # is one argument; the product adapter must normalize it before option parsing.
    $inline = '& $args[0] @($args | Select-Object -Skip 1); exit $LASTEXITCODE'
    $splat = '$target=$args[0]; $tail=@($args | Select-Object -Skip 1); & $target @tail; exit $LASTEXITCODE'
    $childArgs = @('pwsh', '-c', 'exit 0', '-v', '-q', 'path with spaces', 'literal $() and `ticks')
    $reason = 'argv suite: deliberate shared lock; separate paths cannot test nested forwarding'
    $ready = Join-Path $fixture 'ready with spaces'
    foreach ($entry in @('File', 'InlineArray', 'VariableSplat')) {
        if ($entry -eq 'File') {
            & $pwsh -NoProfile -File $adapter -TimeoutSec 1 -Reason $reason -ReadyFile $ready @childArgs
        } else {
            $wrapper = if ($entry -eq 'InlineArray') { $inline } else { $splat }
            & $pwsh -NoProfile -CommandWithArgs $wrapper $adapter -TimeoutSec 1 -Reason $reason -ReadyFile $ready @childArgs
        }
        Assert-True ($LASTEXITCODE -eq 0) "$entry exits successfully without starting Python"
        $actual = Read-Argv
        # The PowerShell script shim consumes native '--' as end-of-parameters.
        $expected = @((Join-Path (Split-Path $adapter) 'pytest-lock.py'), '--timeout', '1', '--reason', $reason, '--ready-file', $ready) + $childArgs
        Assert-True (($actual | ConvertTo-Json -Compress) -ceq ($expected | ConvertTo-Json -Compress)) "$entry preserves options, flags and literal argv"
        Write-Output "PASS: $entry forwards timeout=1 and $($childArgs.Count) intact child arguments"
    }
    & $pwsh -NoProfile -CommandWithArgs $inline $adapter -Reason $reason @childArgs
    $actual = Read-Argv
    Assert-True ($LASTEXITCODE -eq 0 -and $actual[2] -eq '1800') 'default lock wait survives inline-array forwarding'
    $env:FS58_CHILD_EXIT = '7'
    & $pwsh -NoProfile -File $adapter -Reason $reason @childArgs
    Assert-True ($LASTEXITCODE -eq 7) 'adapter retains child failure exit code'
    $env:FS58_CHILD_EXIT = '0'

    foreach ($entry in @('File','InlineArray','VariableSplat')) {
        foreach ($reasonArgs in @(@(), @('-Reason',''), @('-Reason','   '))) {
            Remove-Item -LiteralPath $env:FS58_ARGV_CAPTURE -ErrorAction SilentlyContinue
            $output = if ($entry -eq 'File') {
                & $pwsh -NoProfile -File $adapter @reasonArgs @childArgs 2>&1
            } else {
                $wrapper = if ($entry -eq 'InlineArray') { $inline } else { $splat }
                & $pwsh -NoProfile -CommandWithArgs $wrapper $adapter @reasonArgs @childArgs 2>&1
            }
            Assert-True ($LASTEXITCODE -eq 2 -and ($output -join ' ') -match 'EXCLUSIVE_REASON_REQUIRED' -and -not (Test-Path $env:FS58_ARGV_CAPTURE)) "$entry requires a reason before starting any child"
        }
    }

    Write-Output "SUMMARY: $passed passed; no Python started"
} finally {
    $env:PATH = $savedPath
    $env:FS58_ARGV_CAPTURE = $savedCapture
    $env:FS58_CHILD_EXIT = $savedExit
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'fixture cleanup escaped temp directory'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
