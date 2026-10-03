$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../bench/run-bench.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome=Enter-RouterTestCodexHome
$script:checks=0
function Assert($Condition,$Message){if(-not $Condition){throw $Message};$script:checks++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('router-bench-json-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    # Exact successful answer from saved live call-034; no live model invocation.
    $saved=Get-Content (Join-Path $PSScriptRoot 'fixtures/bench-ddq-response.json') -Raw | ConvertFrom-Json -AsHashtable
    $probe=Join-Path $root 'probe.py'
    [IO.File]::WriteAllText($probe,@'
import json, sys
line = sys.stdin.readline()
try:
    value = json.loads(line)
except ValueError as error:
    print(json.dumps({'error': str(error), 'control': ord(line[195])}))
else:
    print(json.dumps(value, ensure_ascii=False))
'@)
    function Probe($Value,[switch]$Utf8) {
        $psi=[Diagnostics.ProcessStartInfo]::new()
        $psi.FileName=(Get-Command python).Source
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        if($Utf8){Set-BenchProcessEncoding -ProcessInfo $psi -Python}
        else {
            # Reproduce the observed Windows default independent of console locale.
            $psi.StandardInputEncoding=[Text.Encoding]::GetEncoding(437)
            $psi.Environment['PYTHONIOENCODING']='cp1252'
        }
        [void]$psi.ArgumentList.Add($probe)
        $process=[Diagnostics.Process]::Start($psi)
        try {
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine(($Value|ConvertTo-Json -Depth 40 -Compress));$process.StandardInput.Close()
            if(-not $process.WaitForExit(10000)){throw 'Probe timeout'}
            if($process.ExitCode -ne 0){throw $stderr.GetAwaiter().GetResult()}
            return ($stdout.GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable)
        } finally {if(-not $process.HasExited){$process.Kill($true)};$process.Dispose()}
    }
    # Use only answer first so the failure offset is deterministic.
    $before=Probe ([ordered]@{value=[ordered]@{answer=$saved.answer}})
    Assert ($before.error -ceq 'Invalid control character at: line 1 column 196 (char 195)' -and $before.control -eq 21) 'Original failure was not reproduced exactly'
    $after=Probe @{value=$saved} -Utf8
    Assert ($after.value.answer -ceq $saved.answer -and $after.value.raw.result -ceq $saved.raw.result) 'Saved DDQ answer/raw result changed through UTF-8 IPC'
    $unicode="§ snow 雪 emoji 😀 Tibetan བོད་`nline two`ttab and quote `""
    $after=Probe @{value=$unicode} -Utf8
    Assert ($after.value -ceq $unicode) 'Multilingual/newline/quote bidirectional IPC changed bytes'

    # Adjacent production adapters use the same redirected stream defaults.
    $fakeServer=Join-Path $root 'unicode-appserver.py'
    $server=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fake-appserver.py'))
    $literal=$unicode|ConvertTo-Json -Compress
    $server=$server.Replace("'Synthetic fixture\nexact bytes'",$literal).Replace("'synthetic answer'",$literal)
    [IO.File]::WriteAllText($fakeServer,$server)
    $request=@{vendor='codex';model='gpt-6.1-sol';effort='high';prompt=$unicode}
    $actual=Invoke-BenchCli -Request $request -CodexCommandResolver { @((Get-Command python).Source,$fakeServer,'ok') }
    Assert ($actual.status -eq 'ok' -and $actual.answer -ceq $unicode) 'Codex production adapter Unicode prompt/answer changed'
    $fakeClaude=Join-Path $root 'unicode-claude.ps1'
    [IO.File]::WriteAllText($fakeClaude,@'
$answer=[Console]::In.ReadToEnd()
[Console]::WriteLine((@{result=$answer;modelUsage=@{'claude-opus-5-5'=@{}}}|ConvertTo-Json -Depth 10 -Compress))
'@)
    $request.vendor='claude';$request.model='claude-opus-5-5'
    $actual=Invoke-BenchCli -Request $request -ClaudeResolver {$fakeClaude}
    Assert ($actual.status -eq 'ok' -and $actual.answer -ceq $unicode) 'Claude production adapter Unicode prompt/answer changed'

    # Exercise the real bench_engine callback, including answer, envelope and outcome.
    $tasks=Join-Path $root 'tasks'
    [void][IO.Directory]::CreateDirectory($tasks)
    Copy-Item -LiteralPath (Join-Path $script:BenchRoot 'tasks/analysis-ddq-gaps') -Destination $tasks -Recurse
    $rubric=Get-Content (Join-Path $tasks 'analysis-ddq-gaps/golden/rubric.json') -Raw|ConvertFrom-Json
    $script:answers=0;$script:outcomes=0;$script:envelopes=0
    $outcome={param($r)
        if($r.response.status -eq 'ok'){
            Assert ($r.response.answer -ceq $saved.answer) 'Outcome answer changed'
            $script:outcomes++
        }
    }
    $envelope={param($a)
        Assert ($a -ceq $saved.answer.Substring(11)) 'Engine answer body changed before envelope'
        $script:envelopes++
        New-PromptEnvelope -Label 'BENCH ANSWER EVIDENCE' -Content $a
    }
    # The judge sees the timestamp-stripped body, so test that exact form.
    $invoke={param($r)
        if($r.purpose -eq 'answer'){$script:answers++;return $saved}
        Assert ($r.prompt.Contains($saved.answer.Substring(11))) 'Unicode answer changed in judge prompt'
        $scores=@{};foreach($line in $rubric.lines){$scores[$line.id]=1}
        @{status='ok';answer=(@{scores=$scores}|ConvertTo-Json -Compress)}
    }
    $result=Invoke-RouterBench -Job deep-thinker -Candidate claude-opus-5-5 -Incumbent gpt-6.1-sol -StateDir $root -Tasks $tasks -CliInvoker $invoke -Limits {param($v) @{blocked=$false}} -Outcome $outcome -Envelope $envelope -NoAlerts
    Assert ($result.raw_gate -eq 'pass' -and $result.candidate.unknown -eq 0 -and $result.incumbent.unknown -eq 0) 'Saved successful response became unknown in real engine'
    Assert ($script:answers -eq 9 -and $script:outcomes -eq 9 -and $script:envelopes -eq 9) 'Unexpected retries or missing answer/envelope/outcome callbacks'
    Write-Output 'PASS: IBM437 column196 reproduction, saved response, multilingual bidirectional IPC, real callback no retries'
} finally {Exit-RouterTestCodexHome $fixtureCodexHome;Remove-CodexTempDirectory -Path $root -ExpectedLeafPrefix 'router-bench-json-'}
Write-Output "SUMMARY: $script:checks passed; 0 failed"
