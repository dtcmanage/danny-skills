$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../bench/run-bench.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
$script:benchChecks=0
function Assert($Condition,$Message){if(-not $Condition){throw $Message};$script:benchChecks++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('bench-refusal-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $fake=Join-Path $root 'claude-fixture.ps1'
    $request=@{vendor='claude';model='claude-opus-5-5';effort='low';prompt='synthetic'}
    $reset='2099-10-02T20:00:00Z'
    foreach($case in @('error-json','nonzero-json','nonzero-text','error-no-identity','mismatch')) {
        $doc=@{result="Usage limit reached; resets at $reset sk-ant-SYNTHETICSECRET123";is_error=$true;
            config=@{refresh_token='CONFIG_SECRET_SENTINEL'};modelUsage=@{'claude-opus-5-5'=@{inputTokens=0;outputTokens=0}}}
        $exit=0
        if($case -like 'nonzero*'){$exit=1}
        if($case -eq 'error-no-identity'){$doc.Remove('modelUsage')}
        if($case -eq 'mismatch'){$doc.is_error=$false;$doc.result='normal answer';$doc.modelUsage=@{'claude-haiku-4-5'=@{inputTokens=1;outputTokens=1}}}
        $payload=$doc|ConvertTo-Json -Depth 8 -Compress
        if($case -eq 'nonzero-text'){$payload="Usage limit reached; resets at $reset api_key=SECRET_SENTINEL"}
        $escaped=$payload.Replace("'","''")
        [IO.File]::WriteAllText($fake,"[Console]::In.ReadToEnd() | Out-Null`n[Console]::Out.WriteLine('$escaped')`n[Console]::Error.WriteLine('refresh_token=STDERR_SECRET_SENTINEL')`nexit $exit")
        $detail=''
        try {$null=Invoke-BenchCli -Request $request -ClaudeResolver {$fake} -TimeoutMs 10000;throw 'Adapter accepted error'}
        catch {$detail=$_.Exception.Message}
        if($case -eq 'mismatch'){
            Assert ($detail -match 'Requested|model changed') 'Identity mismatch not rejected independently'
            Assert (-not (Test-RouterLimitRefusal -Vendor claude -Text $detail).refused) 'Mismatch mistaken for quota'
        } else {
            $refusal=Test-RouterLimitRefusal -Vendor claude -Text $detail
            Assert $refusal.refused "Lost refusal: $case"
            Assert ([datetimeoffset]$refusal.reset_at_utc -eq [datetimeoffset]$reset) "Lost reset: $case"
            Assert ($detail -notmatch 'SYNTHETICSECRET123|CONFIG_SECRET_SENTINEL|STDERR_SECRET_SENTINEL|=SECRET_SENTINEL') "Secret leaked: $case"
        }
    }
    foreach($vendor in @('claude','codex')) {
        $state=Join-Path $root $vendor
        $other=Join-Path $root ($vendor+'-unrelated')
        [void][IO.Directory]::CreateDirectory($other)
        [IO.File]::WriteAllText((Join-Path $other 'vendor-blocks.json'),'[]')
        $before=Get-FileHash (Join-Path $other 'vendor-blocks.json')
        $script:dispatches=@{claude=0;codex=0}
        $invoke={param($r)
            $script:dispatches[$r.vendor]++
            if($r.vendor -eq $vendor){throw "ERROR: Usage limit reached; resets at $reset"}
            return @{status='unknown';detail='synthetic offline'}
        }
        $candidate=if($vendor -eq 'claude'){'claude-opus-5-5'}else{'gpt-6.1-sol'}
        $incumbent=if($vendor -eq 'claude'){'gpt-6.1-sol'}else{'claude-opus-5-5'}
        $result=Invoke-RouterBench -Job fast -Candidate $candidate -Incumbent $incumbent -EffortOverride low -StateDir $state -CliInvoker $invoke -Limits {param($v) @{blocked=$false}} -Diagnosis {param($v,$e) @{verdict='synthetic'}} -NoAlerts -TimeoutMs 10000
        Assert ($script:dispatches[$vendor] -eq 1) "Repeated exhausted vendor dispatch: $vendor"
        Assert ($script:dispatches[$incumbent.StartsWith('claude-') ? 'claude' : 'codex'] -eq 12) 'Other vendor improperly blocked'
        $blocks=@(Get-Content (Join-Path $state 'vendor-blocks.json') -Raw|ConvertFrom-Json)
        Assert ($blocks.Count -eq 1 -and $blocks[0].vendor -eq $vendor) 'Wrong block scope'
        Assert ([datetimeoffset]$blocks[0].reset_at_utc -eq [datetimeoffset]$reset -and $blocks[0].resume_after_source -eq 'refusal-reset') 'Wrong persisted reset'
        Assert ($result.raw_gate -eq 'unknown' -and $result.outcomes.Count -eq 24) 'Unknown/retry requirements changed'
        Assert ((Get-FileHash (Join-Path $other 'vendor-blocks.json')).Hash -eq $before.Hash) 'Unrelated state changed'
        $again=Invoke-RouterBench -Job fast -Candidate $candidate -Incumbent $candidate -EffortOverride low -StateDir $state -CliInvoker {throw 'must not dispatch persisted block'} -Limits {param($v) @{blocked=$false}} -NoAlerts -TimeoutMs 10000
        Assert ($again.raw_gate -eq 'unknown') 'Persisted block not respected across runs'
    }
    Write-Output 'PASS: 5 real-host Claude adapter cases; 2 vendor refusal/persistence/scoping cases; no vendor calls'
} finally {
    Exit-RouterTestCodexHome $fixtureCodexHome
    Remove-CodexTempDirectory -Path $root -ExpectedLeafPrefix 'bench-refusal-'
}

Write-Output "SUMMARY: $script:benchChecks passed; 0 failed"
