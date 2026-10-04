$ErrorActionPreference='Stop'

. (Join-Path $PSScriptRoot '../bench/run-bench.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
$script:benchChecks=0
function Assert($Condition,$Message){if(-not $Condition){throw $Message};$script:benchChecks++}
$peer=Join-Path $PSScriptRoot 'fake-appserver-accounting.py'
$root=Join-Path ([IO.Path]::GetTempPath()) ('m02-host-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$reset='2099-10-02T20:00:00Z'
try {
    foreach($case in @('quota-notification','quota-turn')) {
        $vendor='codex'
        $state=Join-Path $root $case
        $other=Join-Path $root ($case+'-unrelated')
        [void][IO.Directory]::CreateDirectory($other)
        [IO.File]::WriteAllText((Join-Path $other 'vendor-blocks.json'),'[]')
        $before=Get-FileHash (Join-Path $other 'vendor-blocks.json')
        $script:dispatches=@{claude=0;codex=0}
        $invoke={param($r)
            $script:dispatches[$r.vendor]++
            if($r.vendor -eq $vendor){
                $r.effort='high';$r.prompt="Synthetic fixture`nexact bytes"
                $reply=Invoke-BenchCli -Request $r -CodexCommandResolver {(Get-Command python).Source; $peer; $case} -TimeoutMs 5000
                Assert ($reply.status -eq 'unknown' -and $reply.usage_partial -and $reply.usage.input -eq 55) 'Adapter lost unknown partial usage'
                return $reply
            }
            return @{status='unknown';detail='synthetic offline'}
        }
        $candidate=if($vendor -eq 'claude'){'claude-opus-5-5'}else{'gpt-6.1-sol'}
        $incumbent=if($vendor -eq 'claude'){'gpt-6.1-sol'}else{'claude-opus-5-5'}
        $result=Invoke-RouterBench -Job fast -Candidate $candidate -Incumbent $incumbent -EffortOverride low -StateDir $state -CliInvoker $invoke -Limits {param($v) @{blocked=$false}} -Diagnosis {param($v,$e) @{verdict='synthetic'}} -NoAlerts -TimeoutMs 10000
        Assert ($script:dispatches[$vendor] -eq 1) "Repeated exhausted vendor dispatch: $vendor"
        Assert ($script:dispatches[$incumbent.StartsWith('claude-') ? 'claude' : 'codex'] -eq 18) 'Other vendor improperly blocked'
        $blocks=@(Get-Content (Join-Path $state 'vendor-blocks.json') -Raw|ConvertFrom-Json)
        Assert ($blocks.Count -eq 1 -and $blocks[0].vendor -eq $vendor) 'Wrong block scope'
        Assert ([datetimeoffset]$blocks[0].reset_at_utc -eq [datetimeoffset]$reset -and $blocks[0].resume_after_source -eq 'refusal-reset') 'Wrong persisted reset'
        Assert ($result.raw_gate -eq 'unknown' -and $result.outcomes.Count -eq 36) 'Unknown/retry requirements changed'
        Assert ((Get-FileHash (Join-Path $other 'vendor-blocks.json')).Hash -eq $before.Hash) 'Unrelated state changed'
        Assert ((Get-ChildItem $state -File -Recurse | Get-Content -Raw) -notmatch 'SECRET_SENTINEL') 'Secret persisted'
        $again=Invoke-RouterBench -Job fast -Candidate $candidate -Incumbent $candidate -EffortOverride low -StateDir $state -CliInvoker {throw 'must not dispatch persisted block'} -Limits {param($v) @{blocked=$false}} -NoAlerts -TimeoutMs 10000
        Assert ($again.raw_gate -eq 'unknown') 'Persisted block not respected across runs'
    }
    Write-Output 'PASS: 2 production adapter + host quota cases; one exhausted call; stale limits; scoped block/reset; other vendor continues; partial usage; secrets absent'
} finally {Exit-RouterTestCodexHome $fixtureCodexHome; Remove-CodexTempDirectory -Path $root -ExpectedLeafPrefix 'm02-host-'}

Write-Output "SUMMARY: $script:benchChecks passed; 0 failed"
