# Static command fixtures only: this suite starts no Python, pytest or grader.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../pytest-command.ps1')
$passed = 0
foreach ($case in @(
    @{ command = 'python -m pytest tests -q'; expected = $true },
    @{ command = '& "C:\Python\python.exe" -B -m pytest tests'; expected = $true },
    @{ command = 'pytest.exe -v'; expected = $true },
    @{ command = 'pwsh -Command "python -m pytest tests"'; expected = $true },
    @{ command = 'python -c "import pytest; raise SystemExit(pytest.main([]))"'; expected = $true },
    @{ command = 'Write-Output "pytest is deferred"'; expected = $false },
    @{ command = 'Write-Output ok # pytest'; expected = $false },
    @{ command = 'python scripts/tests/test_pytest_lock.py'; expected = $false },
    @{ command = 'pwsh -File tests/test-pytest-command.ps1'; expected = $false },
    @{ command = 'python -c "print(''pytest'')"'; expected = $false },
    @{ executable = 'C:\tools\pytest.exe'; arguments = @('-q'); expected = $true },
    @{ executable = 'C:\tools\python.exe'; arguments = @('-m','pytest','-q'); expected = $true },
    @{ executable = 'python'; arguments = @('-c','import pytest; pytest.main([])'); expected = $true },
    @{ executable = 'pwsh'; arguments = @('-File','pytest-notes.ps1'); expected = $false }
)) {
    $arguments = @{}
    if ($case.ContainsKey('command')) { $arguments.Command = $case.command }
    if ($case.ContainsKey('executable')) { $arguments.Executable = $case.executable; $arguments.ArgumentList = $case.arguments }
    $actual = Test-DannyPytestCommand @arguments
    if ($actual -ne $case.expected) { throw "ASSERT_FAIL: $($case | ConvertTo-Json -Compress) produced $actual" }
    $passed++
}
Write-Output "PASS: pytest command fixtures; SUMMARY: $passed passed"
