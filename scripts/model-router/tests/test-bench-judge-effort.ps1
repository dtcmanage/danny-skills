$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../bench/run-bench.ps1')
. (Join-Path $PSScriptRoot '../check-new-models.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixture = Enter-RouterTestCodexHome
$priorState = $env:DT_MODEL_ROUTER_STATE
$root = Join-Path ([IO.Path]::GetTempPath()) ('bench-judge-effort-' + [guid]::NewGuid().ToString('N'))
$env:DT_MODEL_ROUTER_STATE = $root
$script:checks = 0
function Check($Condition, $Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'bench'))
    $configPath = Join-Path $root 'bench/judge-config.json'
    $config = Get-Content (Join-Path $script:BenchRoot 'bench-config.json') -Raw | ConvertFrom-Json -AsHashtable
    $config.Remove('judge_effort')
    $config.judges.codex = 'gpt-6-astra-custom'
    $config | ConvertTo-Json -Depth 10 | Set-Content $configPath
    $before = [IO.File]::ReadAllBytes($configPath)
    $rubric = Get-Content (Join-Path $script:BenchRoot 'tasks/writing-letter-section/golden/rubric.json') -Raw | ConvertFrom-Json
    $script:expectedEffort = 'high'
    $script:answerEfforts = @()
    $invoke = { param($r)
        if ($r.purpose -eq 'answer') {
            $script:answerEfforts += $r.effort
            return @{status='ok';answer='synthetic evidence'}
        }
        Check ($r.effort -eq $script:expectedEffort) 'Fixed judge effort not honored'
        $scores = @{}; foreach($line in $rubric.lines) { $scores[$line.id] = 1 }
        return @{status='ok';answer=(@{scores=$scores} | ConvertTo-Json -Compress)}
    }
    $benchArgs = @{Job='writer';Candidate='gpt-6.1-sol';Incumbent='claude-opus-5-5';StateDir=$root;EffortOverride='medium';
              CliInvoker=$invoke;Limits={param($v) @{blocked=$false}};Outcome={param($r)};NoAlerts=$true}
    $legacy = Invoke-RouterBench @benchArgs
    Check ($legacy.judge_effort -eq 'high' -and $legacy.judge_pair.codex -eq 'gpt-6-astra-custom') 'Legacy default or pair changed'
    Check ([Convert]::ToHexString($before) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes($configPath))) 'Read-time fallback mutated state'
    Check ('medium' -in $script:answerEfforts -and 'low' -in $script:answerEfforts) 'Candidate effort-down missing'
    Update-RouterBenchJudges @()
    $migrated = Read-RouterJsonObject $configPath
    Check ($migrated.judge_effort -eq 'high' -and $migrated.judges.codex -eq 'gpt-6-astra-custom') 'Catalog update legacy migration changed pair'
    $migrated.judge_effort = 'medium'; Write-RouterJsonAtomic $configPath $migrated
    Update-RouterBenchJudges @()
    Check ((Read-RouterJsonObject $configPath).judge_effort -eq 'medium') 'Explicit valid effort replaced'
    $script:expectedEffort = 'medium'
    $explicit = Invoke-RouterBench @benchArgs
    Check ($explicit.judge_effort -eq 'medium') 'Persisted explicit effort ignored'
    $migrated.judge_effort = 'max'; Write-RouterJsonAtomic $configPath $migrated
    Update-RouterBenchJudges @()
    Check ((Read-RouterJsonObject $configPath).judge_effort -eq 'max') 'Invalid explicit value silently defaulted'
    try { $null = Invoke-RouterBench @benchArgs; throw 'Invalid explicit effort accepted' }
    catch { Check ($_.Exception.Message -match 'judge_effort') 'Invalid effort did not fail engine validation' }
    $config | ConvertTo-Json -Depth 10 | Set-Content $configPath
    try { $null = Invoke-RouterBench @benchArgs -ConfigPath $configPath; throw 'Explicit missing effort accepted' }
    catch { Check ($_.Exception.Message -match 'judge_effort') 'Explicit missing effort must validate strictly' }
    Write-Output "SUMMARY: $script:checks passed; 0 failed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    Exit-RouterTestCodexHome $fixture
}
