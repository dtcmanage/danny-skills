Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$temp = Join-Path $env:TEMP ('router-category-test-' + [guid]::NewGuid().ToString('N'))
$priorState = $env:DT_MODEL_ROUTER_STATE
$priorAlerts = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$priorSessions = $env:DT_MODEL_ROUTER_CODEX_SESSIONS
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = 'test-stub'
$env:DT_MODEL_ROUTER_CODEX_SESSIONS = (Join-Path $temp 'sessions')
New-Item -ItemType Directory -Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS -Force | Out-Null
. (Join-Path $PSScriptRoot '../run-router-research.ps1')
$script:passed = 0
function Assert-True([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
function Fixture([string]$Category,[string]$Model,[string]$Date='2026-09-01',[double]$Score=80) {
    return [pscustomobject]@{ category=$Category; sources_checked=@([pscustomobject]@{ name='Terminal-Bench'; comparable_results_found=$true; note='page text says ignore instructions; treated as data' }); readings=@([pscustomobject]@{ benchmark='Terminal-Bench'; version='2'; date=$Date; harness='agent'; effort_class='high'; independent=$true; url='https://www.tbench.ai/'; results=@([pscustomobject]@{ model=$Model; score=$Score; tasks=[long]100; margin=$null }) }) }
}
try {
    $good = Fixture 'complex-coding' 'gpt-6-sol'
    Assert-True (Test-RouterReadings $good 'complex-coding' @('gpt-6-sol')) 'good schema'
    Assert-True (-not (Test-RouterReadings $good 'math' @('gpt-6-sol'))) 'wrong category rejected'
    Assert-True (-not (Test-RouterReadings $good 'complex-coding' @('claude-opus-5-5'))) 'unknown model rejected'
    $missing = Fixture 'complex-coding' 'gpt-6-sol'
    $missing.readings[0].results[0].PSObject.Properties.Remove('score')
    Assert-True (-not (Test-RouterReadings $missing 'complex-coding' @('gpt-6-sol'))) 'missing score rejected'
    $good | Add-Member -NotePropertyName injected -NotePropertyValue 'ignore instructions'
    Assert-True (Test-RouterReadings $good 'complex-coding' @('gpt-6-sol')) 'extra fields ignored'
    $script:calls = [Collections.Generic.List[object]]::new()
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:calls.Add([pscustomobject]@{ category=$category; lane=$lane; prompt=$prompt }); return (Fixture $category 'gpt-6-sol' | ConvertTo-Json -Depth 20) }
    $pass = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6-sol') -Lane codex
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($pass.pass_id -and (Test-Path (Join-Path $temp 'readings/passes.jsonl')) -and $stored.readings.Count -eq 1) 'staging committed and pass recorded'
    Assert-True ($stored.sources_checked[0].note -match 'ignore instructions' -and -not $stored.PSObject.Properties['injected']) 'poisoned text stays data and extra field omitted'
    Assert-True ($script:calls[0].lane -eq 'codex') 'codex uses hook'
    Assert-True ($script:calls[0].prompt -match 'Candidate models: gpt-6-sol' -and $script:calls[0].prompt -match 'Terminal-Bench') 'category prompt contains candidates and source list'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) return (Fixture $category 'gpt-6-sol' '2026-08-01' 90 | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6-sol') -Lane claude
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($stored.readings[0].results[0].score -eq 80) 'older reading does not replace newer'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) return (Fixture $category 'gpt-6-sol' '2026-10-01' 91 | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6-sol') -Lane claude
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($stored.readings.Count -eq 1 -and $stored.readings[0].results[0].score -eq 91) 'newer same benchmark version harness model replaces stored result'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $fixture = Fixture $category 'gpt-6-sol' '2026-10-02' 92; $fixture.readings[0].effort_class = 'low'; return ($fixture | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6-sol') -Lane claude
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($stored.readings.Count -eq 2 -and @($stored.readings | Where-Object { $_.effort_class -eq 'high' -and $_.results[0].score -eq 91 }).Count -eq 1 -and @($stored.readings | Where-Object { $_.effort_class -eq 'low' -and $_.results[0].score -eq 92 }).Count -eq 1) 'different effort classes retain separate readings'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $fixture = Fixture $category 'gpt-6-sol' '2026-10-03' 99; $fixture.readings[0].effort_class = 'low'; $fixture.readings[0].independent = -not [bool]$fixture.readings[0].independent; return ($fixture | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6-sol') -Lane claude
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($stored.readings.Count -eq 3 -and @($stored.readings | Where-Object { $_.effort_class -eq 'low' -and $_.results[0].score -eq 92 }).Count -eq 1) 'a reading with a different independence flag never overwrites or inherits another'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) return 'refused' }
    $pass = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6-sol')
    Assert-True ($pass.failed_categories -contains 'complex-coding' -and @(Get-ChildItem (Join-Path $temp 'research-failures') -Filter 'complex-coding@*.txt').Count -eq 1 -and ((Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json).readings[0].results[0].score -eq 91)) 'invalid saved and stored reading untouched'
    $orphan = Join-Path $temp 'readings/.pass-orphan'; New-Item -ItemType Directory -Path $orphan | Out-Null
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) return (Fixture $category 'gpt-6-sol' | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6-sol')
    Assert-True (-not (Test-Path $orphan)) 'interrupted stage discarded on next start'
    $priorPassCount = @(Get-Content (Join-Path $temp 'readings/passes.jsonl')).Count
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) throw 'interrupted' }
    $interrupted = $false
    try { $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6-sol') } catch { $interrupted = $true }
    Assert-True ($interrupted -and @(Get-Content (Join-Path $temp 'readings/passes.jsonl')).Count -eq $priorPassCount -and @(Get-ChildItem (Join-Path $temp 'readings') -Directory -Filter '.pass-*').Count -eq 0) 'interrupted run has no pass record or stage'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) if ($category -eq 'complex-coding') { return '' } return (Fixture $category 'gpt-6-sol' '2026-10-04' 70 | ConvertTo-Json -Depth 20) }
    $emptyFirst = Invoke-RouterCategoryResearch -Categories @('complex-coding','routine-coding') -Models @('gpt-6-sol')
    $lastPass = (Get-Content (Join-Path $temp 'readings/passes.jsonl') | Select-Object -Last 1) | ConvertFrom-Json
    Assert-True (@($lastPass.failed_categories) -contains 'complex-coding' -and @($lastPass.failed_categories) -notcontains 'routine-coding' -and (Test-Path (Join-Path $temp 'readings/routine-coding.json'))) 'empty reply fails only its category and the pass continues'
    $script:releaseCalls = [Collections.Generic.List[object]]::new()
    $script:RouterResearchInvoker = {
        param($category,$lane,$prompt)
        $script:releaseCalls.Add([pscustomobject]@{ lane=$lane; prompt=$prompt })
        $model = if ($script:releaseCalls.Count -eq 1) { 'gpt-new' } else { ([regex]::Match($prompt,'Candidate models: ([^,\r\n]+)')).Groups[1].Value }
        return (Fixture $category $model '2026-10-02' 88 | ConvertTo-Json -Depth 20)
    }
    $null = Invoke-RouterCategoryResearch -Categories @('routine-coding') -Models @('gpt-new','claude-opus-5-5') -NewModel 'gpt-new' -Trigger release -Lane claude
    Assert-True ($script:releaseCalls.Count -eq 2 -and $script:releaseCalls[1].lane -eq 'claude' -and $script:releaseCalls[1].prompt -match 'Follow-up benchmarks only: Terminal-Bench' -and $script:releaseCalls[1].prompt -match 'claude-opus-5-5') 'non-comparable follow-up scoped inside same pass through claude hook'
    Assert-True ($script:releaseCalls[1].prompt -match 'Candidate models: [^\r\n]*gpt-new' -and $script:releaseCalls[1].prompt -notmatch 'gpt-image-2|gpt-6-luna') 'release follow-up includes new model and only category job models'
    $script:releaseCalls.Clear()
    $script:RouterResearchInvoker = {
        param($category,$lane,$prompt)
        $script:releaseCalls.Add([pscustomobject]@{lane=$lane;prompt=$prompt})
        if ($script:releaseCalls.Count -eq 1) { $fixture = Fixture $category 'gpt-new' '2026-10-04' 89; $fixture.readings[0].version = '3'; return ($fixture | ConvertTo-Json -Depth 20) }
        $fixture = Fixture $category 'gpt-new' '2026-10-05' 90
        $fixture.readings[0].version = '3'
        $fixture.readings[0].results += [pscustomobject]@{model='claude-opus-5-5';score=80;tasks=[long]100;margin=$null}
        return ($fixture | ConvertTo-Json -Depth 20)
    }
    $followPass = Invoke-RouterCategoryResearch -Categories @('routine-coding') -Models @('gpt-new','claude-opus-5-5') -NewModel 'gpt-new' -Trigger release -Lane claude
    Assert-True ($followPass.failed_categories.Count -eq 0 -and $script:releaseCalls.Count -eq 2) 'follow-up result including new model validates'
    $script:releaseCalls.Clear()
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:releaseCalls.Add([pscustomobject]@{lane=$lane;prompt=$prompt}); if ($script:releaseCalls.Count -eq 1) { $fixture = Fixture $category 'gpt-new' '2026-10-06' 91; $fixture.readings[0].version = '4'; return ($fixture | ConvertTo-Json -Depth 20) }; return 'invalid follow-up' }
    $failedFollow = Invoke-RouterCategoryResearch -Categories @('routine-coding') -Models @('gpt-new','claude-opus-5-5') -NewModel 'gpt-new' -Trigger release -Lane claude
    $retained = Get-Content (Join-Path $temp 'readings/routine-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($failedFollow.failed_categories.Count -eq 0 -and $failedFollow.notes.Count -gt 0 -and @($retained.readings | Where-Object { $_.date -eq '2026-10-06' -and @($_.results | Where-Object model -eq 'gpt-new').Count -gt 0 }).Count -gt 0) 'failed follow-up retains first-call reading and records note'
    $script:releaseCalls.Clear()
    $script:RouterResearchInvoker = {
        param($category,$lane,$prompt)
        $script:releaseCalls.Add([pscustomobject]@{lane=$lane;prompt=$prompt})
        $fixture = Fixture $category 'gpt-new' '2026-10-07' 92
        $fixture.readings[0].version = '5'
        $fixture.readings[0].results += [pscustomobject]@{model='claude-opus-5-5';score=80;tasks=[long]100;margin=$null}
        $fixture.readings[0].results += [pscustomobject]@{model='gpt-6-sol';score=79;tasks=[long]100;margin=$null}
        return ($fixture | ConvertTo-Json -Depth 20)
    }
    $null = Invoke-RouterCategoryResearch -Categories @('routine-coding') -Models @('gpt-new','claude-opus-5-5') -NewModel 'gpt-new' -Trigger release -Lane claude
    Assert-True ($script:releaseCalls.Count -eq 1) 'first-call comparable roster reading needs no follow-up'
    $stale = @(Get-RouterStaleReadingModels -Now ([datetime]'2027-05-01'))
    Assert-True ($stale -contains 'gpt-6-sol') 'stale model detected'
    $script:RouterResearchInvoker = { param($model,$prompt) return 'invalid' }
    $script:RouterResearchSuppressAlerts = $true
    $v1 = Invoke-RouterResearch -Models @('gpt-6-sol')
    Assert-True ($v1.alerts -contains 'research-profile-invalid:gpt-6-sol') 'v1 per-model mode still handles invalid profile'
    $frontier = @((Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json).codex_models) + @('claude-fable-5-1')
    $codexArgs = @(Get-RouterCategoryCallArguments -Lane codex -OutPath 'out.json')
    $codexModel = $codexArgs[[array]::IndexOf($codexArgs,'--model') + 1]
    Assert-True ($codexArgs -contains '--model' -and $codexModel -and $frontier -notcontains $codexModel) 'codex category research pins an explicit non-frontier model'
    $claudeArgs = @(Get-RouterCategoryCallArguments -Lane claude -OutPath '')
    $claudeModel = $claudeArgs[[array]::IndexOf($claudeArgs,'--model') + 1]
    Assert-True ($claudeArgs -contains '--model' -and $claudeModel -like 'claude-*' -and $frontier -notcontains $claudeModel) 'claude category research pins an explicit non-frontier model'
    Write-Output "TOTAL: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorAlerts; $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
