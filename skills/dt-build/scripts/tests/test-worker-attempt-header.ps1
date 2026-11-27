# Invoked by regression shard 3 with its private project, fake CLIs and router/alert fixtures.
param(
    [Parameter(Mandatory)][string]$FixtureRoot,
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$FakeCodex,
    [Parameter(Mandatory)][string]$FakeClaude
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'worker-attempt-prompt.ps1')
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ }
    else { $script:failures.Add($Message) }
}
$identity = "RUN_ID: fixture-run`nchunk_id: fixture-chunk`n"
$report = "DT_BUILD_REPORT_VERSION: 3`n${identity}attempt: 2`nVERDICT:`nPASS`nCHANGED_FILES:`nNONE`nCOMMANDS_AND_RESULTS:`nNONE`nEVIDENCE_PATHS:`nNONE`nUNRESOLVED_BLOCKERS:`nNONE`nDISCOVERED_ENHANCEMENTS:`nNONE`nCONTINUATION_STATE:`nNONE"
$echo = "DT_BUILD_REPORT_VERSION: 3`n${identity}attempt: 2`nVERDICT:"
$cases = @(
    @{ name = 'missing'; text = $identity + 'fixture'; attempt = 1 },
    @{ name = 'matching'; text = $identity + "attempt: 1`nfixture"; attempt = 1 },
    @{ name = 'normalized'; text = $identity + "  - **Attempt:** ``01``  `r`nfixture"; attempt = 1 },
    @{ name = 'retry-missing'; text = $identity + 'fixture'; attempt = 2 },
    @{ name = 'retry-matching'; text = $identity + "attempt: 2`nfixture"; attempt = 2 },
    @{ name = 'report-echo'; text = $identity + "attempt: 2`nfixture`n$echo"; attempt = 2 },
    @{ name = 'normalized-echo'; text = $identity + "attempt: 2`nfixture`n" + $echo.Replace('attempt: 2', '**Attempt:** `02`'); attempt = 2 },
    @{ name = 'echo-only'; text = "${identity}fixture`n$echo"; attempt = 2 },
    @{ name = 'mismatch'; text = $identity + 'attempt: 2'; attempt = 1; reject = $true },
    @{ name = 'stale-retry'; text = $identity + 'attempt: 1'; attempt = 2; reject = $true },
    @{ name = 'duplicates'; text = $identity + "attempt: 1`nattempt: 1"; attempt = 1; reject = $true },
    @{ name = 'conflicting'; text = $identity + "attempt: 1`nAttempt: 2"; attempt = 1; reject = $true },
    @{ name = 'conflicting-echo'; text = $identity + "attempt: 1`n$echo"; attempt = 1; reject = $true },
    @{ name = 'duplicate-echo'; text = $identity + "attempt: 2`n$echo`n$echo"; attempt = 2; reject = $true },
    @{ name = 'loose-after-report'; text = $identity + "attempt: 2`n" + $echo.Replace("`nattempt:", "`n`nattempt:"); attempt = 2; reject = $true },
    @{ name = 'malformed'; text = $identity + 'attempt: two'; attempt = 2; reject = $true },
    @{ name = 'overflow'; text = $identity + 'attempt: 2147483648'; attempt = 2; reject = $true }
)
# Additional formatting variants exercise the shared parser, including CRLF and no terminal newline.
foreach ($line in @('Attempt: 2', '* attempt: 2', '**attempt**: 2', '`attempt: 2`', 'attempt: `2`', "`tattempt: 2  ")) {
    $actual = Get-WorkerAttemptPrompt -Text ($identity + $line + "`r`nunchanged") -Attempt 2
    Check ($actual.Contains("attempt: 2`r`nunchanged")) "normalize $line while retaining unrelated CRLF text"
}
$saved = @{}
foreach ($name in @('DT_FAKE_UNICODE_PROMPT','DT_FAKE_CHANGED_REPORT','DT_FAKE_CODEX_MODE','DT_FAKE_CLAUDE_MODE')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:DT_FAKE_CODEX_MODE = 'success'; $env:DT_FAKE_CLAUDE_MODE = 'success'
    foreach ($lane in @('codex', 'claude')) {
        $cliArgs = if ($lane -eq 'codex') { @{ CodexCliPath = $FakeCodex } } else { @{ ClaudeCliPath = $FakeClaude; Model = 'claude-sonnet-5' } }
        foreach ($case in $cases) {
            $label = "$lane-$($case.name)"
            $prompt = Join-Path $FixtureRoot "$label-prompt.md"
            $out = Join-Path $FixtureRoot "$label-output.md"
            $env:DT_FAKE_UNICODE_PROMPT = Join-Path $FixtureRoot "$label-stdin.txt"
            $env:DT_FAKE_CHANGED_REPORT = Join-Path $FixtureRoot "$label-report.md"
            [IO.File]::WriteAllText($prompt, $case.text)
            [IO.File]::WriteAllText($env:DT_FAKE_CHANGED_REPORT, $report.Replace('attempt: 2', "attempt: $($case.attempt)"))
            $sourceHash = (Get-FileHash -LiteralPath $prompt).Hash
            $log = & pwsh -NoProfile -File (Join-Path $scripts "invoke-$lane-chunk.ps1") -ProjectPath $ProjectPath -PromptPath $prompt -OutputPath $out @cliArgs -Attempt $case.attempt -Effort low -SelectionReason 'attempt header fixture' -SingleDispatch -Json 2>&1
            $code = $LASTEXITCODE
            Check ((Get-FileHash -LiteralPath $prompt).Hash -ceq $sourceHash) "$label leaves caller file byte-identical"
            if ($case.ContainsKey('reject')) {
                $plainLog = (($log -join ' ') -replace '\x1b\[[0-9;]*m', '') -replace '\s+', ' '
                Check ($code -ne 0 -and $plainLog.Contains("$($lane.ToUpperInvariant())_INVOKE_FAIL: prompt attempt header must equal -Attempt") -and -not (Test-Path $env:DT_FAKE_UNICODE_PROMPT)) "$label rejects before transport: $plainLog"
            } else {
                Check ($code -eq 0) "$label succeeds: $($log -join ' ')"
                if (Test-Path $env:DT_FAKE_UNICODE_PROMPT) {
                    $stdin = [IO.File]::ReadAllText($env:DT_FAKE_UNICODE_PROMPT)
                    Check ($stdin -cmatch "(?m)^attempt: $($case.attempt)\r?$") "$label sends canonical header on actual stdin"
                    Check ($stdin.Contains("echo exactly ``attempt: $($case.attempt)``") -or $stdin.Contains("${identity}attempt: $($case.attempt)`nVERDICT:")) "$label supplies correct output attempt instruction"
                    $prov = Get-Content -Raw "$out.provenance.json" | ConvertFrom-Json
                    Check ($prov.attempt -eq $case.attempt -and $prov.prompt_sha256 -ceq $sourceHash.ToLowerInvariant()) "$label provenance retains attempt and source hash"
                    $stdinHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($stdin))).ToLowerInvariant()
                    Check ($prov.dispatched_prompt_sha256 -ceq $stdinHash) "$label provenance hashes the actual normalized stdin"
                } else { Check $false "$label missing transport receipt" }
            }
        }
        # A correct prompt must never make a wrong report attempt acceptable.
        $prompt = Join-Path $FixtureRoot "$lane-invalid-report-prompt.md"
        $out = Join-Path $FixtureRoot "$lane-invalid-report-output.md"
        [IO.File]::WriteAllText($prompt, $identity + 'fixture')
        [IO.File]::WriteAllText($env:DT_FAKE_CHANGED_REPORT, $report.Replace('attempt: 2', 'attempt: 1'))
        $log = & pwsh -NoProfile -File (Join-Path $scripts "invoke-$lane-chunk.ps1") -ProjectPath $ProjectPath -PromptPath $prompt -OutputPath $out @cliArgs -Attempt 2 -Effort low -SelectionReason 'wrong report attempt fixture' -SingleDispatch -Json 2>&1
        Check ($LASTEXITCODE -ne 0 -and ($log -join ' ') -match 'OUTPUT_INVALID') "$lane retains output validation for stale report attempt"
    }
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
Write-Output "SUMMARY: worker attempt headers: $passed passed; $($failures.Count) failed"
foreach ($failure in $failures) { Write-Output "FAIL: $failure" }
if ($failures.Count) { throw 'worker attempt header regressions failed' }
