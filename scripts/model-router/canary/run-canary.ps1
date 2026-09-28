param([string[]]$Models, [string]$ModelsFile, [ValidateSet('monthly','post-release','manual')][string]$Reason = 'manual', [switch]$DryRun, [switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../router-common.ps1')
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
. (Join-Path $PSScriptRoot '../send-router-alert.ps1')
. (Join-Path $PSScriptRoot '../../invoke-codex-process.ps1')
. (Join-Path $PSScriptRoot '../../claude-cli-result.ps1')

# Read-only first-turn measurements on 2026-09-27: codex exec about 23k input
# tokens; claude -p 25k-57k cache-creation input tokens. Use the upper Claude
# bound to include CLI fixed overhead in each call's estimate.
$script:CanaryCodexInputTokens = 23000
$script:CanaryClaudeCacheWriteTokens = 57000
$script:CanaryOutputTokens = 600
$script:CanaryRuns = 3
$script:CanaryTimeoutMs = 120000
$script:RouterCanaryScriptPath = $PSCommandPath

function Get-CanaryScope {
    param([string[]]$OnlyModels,[switch]$ExcludeFrontier)
    $state = Get-RouterStateDir
    $table = (Read-RouterTable).table
    $picked = @{}
    $eligible = @{}
    foreach ($category in @(Get-RouterCategories | Where-Object { $_ -in @('complex-coding','routine-coding','code-review','mechanical','ui-frontend') })) {
        foreach ($lane in @('codex','claude')) {
            foreach ($candidate in @($table.categories.$category.$lane.candidates)) {
                if (-not $eligible.ContainsKey([string]$candidate.model)) { $eligible[[string]$candidate.model] = [System.Collections.Generic.HashSet[string]]::new() }
                if ($candidate.grade -in @('strong','capable') -and -not $candidate.frontier) { [void]$eligible[[string]$candidate.model].Add($category) }
            }
        }
    }
    foreach ($category in @(Get-RouterCategories)) {
        foreach ($lane in $(if ($category -eq 'image-generation') { @('codex') } else { @('codex','claude') })) {
            try {
                $pick = Resolve-RouterModel -Category $category -Lane $lane -SkipModelCheck
                $picked[[string]$pick.model] = $true
                if (-not $eligible.ContainsKey([string]$pick.model)) { $eligible[[string]$pick.model] = [System.Collections.Generic.HashSet[string]]::new() }
                [void]$eligible[[string]$pick.model].Add($category)
            } catch { throw "CANARY_RESOLVE: $category/$lane`: $($_.Exception.Message)" }
        }
    }
    $new = @{}
    foreach ($item in @(Read-RouterJsonArray -Path (Join-Path $state 'known-models.json'))) {
        if ($item.status -eq 'unprofiled') { $new[[string]$item.id] = [string]$item.lane }
    }
    $flagged = @{}
    foreach ($item in @(Read-RouterJsonArray -Path (Join-Path $state 'drift-flags.json'))) {
        $flagged[[string]$item.model] = $true
        if (-not $eligible.ContainsKey([string]$item.model)) { $eligible[[string]$item.model] = [System.Collections.Generic.HashSet[string]]::new() }
        [void]$eligible[[string]$item.model].Add([string]$item.category)
    }
    $ids = @($picked.Keys + $new.Keys + $flagged.Keys | Sort-Object -Unique)
    if ($ExcludeFrontier) {
        $frontier = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json -Depth 20
        $ids = @($ids | Where-Object { $id = $_; $frontier.codex_models -cnotcontains $id -and -not @($frontier.claude_patterns | Where-Object { $id -like $_ }).Count })
    }
    if ($OnlyModels) { $ids = @($ids | Where-Object { $_ -in $OnlyModels }) }
    $tasks = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'tasks') -Directory | Where-Object Name -ne 'pelican')
    $scope = foreach ($id in $ids) {
        $lane = if ($id -match '^claude-') { 'claude' } else { 'codex' }
        $categories = if ($new.ContainsKey($id) -and -not $eligible.ContainsKey($id)) { @('complex-coding','routine-coding','code-review','mechanical','ui-frontend') } else { @($eligible[$id]) }
        # Folder prefixes preserve the category for coding tasks; the other three names are categories.
        $modelTasks = @($tasks | Where-Object { $cat = if ($_.Name -like 'complex-coding-*') { 'complex-coding' } elseif ($_.Name -like 'routine-coding-*') { 'routine-coding' } else { $_.Name }; $cat -in $categories })
        [pscustomobject]@{ model=$id; lane=$lane; tasks=@($modelTasks | ForEach-Object Name); picked=$picked.ContainsKey($id); new=$new.ContainsKey($id); flagged=$flagged.ContainsKey($id) }
    }
    return @($scope)
}

function Get-CanaryPriceKey {
    param([string]$Model,[object]$PriceModels)
    if (-not $Model) { return $null }
    foreach ($key in @($PriceModels.PSObject.Properties.Name | Sort-Object { $_.Length } -Descending)) {
        if ($Model.Equals($key,[StringComparison]::Ordinal) -or $Model.StartsWith(($key + '-'),[StringComparison]::Ordinal)) { return $key }
    }
    return $null
}

function Get-CanaryBurn {
    param([object[]]$Scope)
    $prices = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/api-prices.json') -Raw | ConvertFrom-Json
    $rows = foreach ($item in $Scope) {
        $count = @($item.tasks).Count * $script:CanaryRuns
        $priceKey = Get-CanaryPriceKey -Model ([string]$item.model) -PriceModels $prices.models
        $price = if ($priceKey) { $prices.models.PSObject.Properties[$priceKey] } else { $null }
        $inputTokens = if ($item.lane -eq 'claude') { $script:CanaryClaudeCacheWriteTokens } else { $script:CanaryCodexInputTokens }
        $inputRate = if (-not $price) { $null } elseif ($item.lane -eq 'claude') { $price.Value.prices_usd_per_mtok.cache_write } else { $price.Value.prices_usd_per_mtok.input }
        $usd = $null
        if ($price -and $null -ne $inputRate -and $null -ne $price.Value.prices_usd_per_mtok.output) {
            $usd = [Math]::Round(($count * ($inputTokens * [double]$inputRate + $script:CanaryOutputTokens * [double]$price.Value.prices_usd_per_mtok.output) / 1000000),6)
        }
        [pscustomobject]@{ model=$item.model; tasks=@($item.tasks).Count; runs=$count; input_tokens=$count*$inputTokens; output_tokens=$count*$script:CanaryOutputTokens; api_equivalent_usd=$usd }
    }
    return [pscustomobject]@{ assumptions=[pscustomobject]@{ runs_per_task=$script:CanaryRuns; codex_input_tokens_per_task=$script:CanaryCodexInputTokens; claude_cache_write_tokens_per_task=$script:CanaryClaudeCacheWriteTokens; output_tokens_per_task=$script:CanaryOutputTokens }; rows=@($rows); input_tokens=[long](@($rows | ForEach-Object { [long]$_.input_tokens }) | Measure-Object -Sum).Sum; output_tokens=[long](@($rows | ForEach-Object { [long]$_.output_tokens }) | Measure-Object -Sum).Sum; priced_usd=[Math]::Round([double](@($rows | Where-Object { $null -ne $_.api_equivalent_usd } | ForEach-Object { [double]$_.api_equivalent_usd }) | Measure-Object -Sum).Sum,6); unpriced=@($rows | Where-Object { $_.runs -gt 0 -and $null -eq $_.api_equivalent_usd } | ForEach-Object model) }
}

function Invoke-CanaryModel {
    param([string]$Model,[string]$Lane,[string]$Prompt)
    if ($Lane -eq 'codex') {
        $out = Join-Path $env:TEMP ('router-canary-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            $result = Invoke-CodexProcess -CodexPath (Get-Command codex -ErrorAction Stop).Source -Arguments @('--ask-for-approval','never','exec','--ignore-user-config','--sandbox','read-only','--cd',$PSScriptRoot,'--model',$Model,'--output-last-message',$out,'-') -Prompt $Prompt -WorkingDirectory $PSScriptRoot -TimeoutMs $script:CanaryTimeoutMs
            if ($result.timed_out -or $result.exit_code -ne 0) { throw 'Codex canary call failed or timed out' }
            return [IO.File]::ReadAllText($out)
        } finally { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
    }
    $claude = (Get-Command claude.ps1,claude.cmd,claude,claude.exe -ErrorAction Stop | Select-Object -First 1).Source
    $cliArgs = @('-p','--model',$Model,'--output-format','json','--no-session-persistence','--strict-mcp-config','--tools','')
    $spec = [Diagnostics.ProcessStartInfo]::new()
    $extension = [IO.Path]::GetExtension($claude).ToLowerInvariant()
    if ($extension -in @('.cmd','.bat')) {
        $spec.FileName = $env:ComSpec
        $quoted = '"' + $claude.Replace('"','""') + '"'
        $quotedArgs = @($cliArgs | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' })
        $cliArgs = @('/d','/s','/c',($quoted + ' ' + ($quotedArgs -join ' ')))
    } elseif ($extension -eq '.ps1') { $spec.FileName = (Get-Command pwsh -ErrorAction Stop).Source; $cliArgs = @('-NoProfile','-File',$claude) + $cliArgs }
    else { $spec.FileName = $claude }
    $spec.UseShellExecute = $false; $spec.CreateNoWindow = $true
    $spec.RedirectStandardInput = $true; $spec.RedirectStandardOutput = $true; $spec.RedirectStandardError = $true
    foreach ($arg in $cliArgs) { [void]$spec.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($spec)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $inputWrite = $process.StandardInput.WriteAsync($Prompt)
        if (-not $inputWrite.Wait(5000)) { $process.Kill($true); throw 'Claude canary prompt write timed out' }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($script:CanaryTimeoutMs)) { $process.Kill($true); throw 'Claude canary call timed out' }
        if ($process.ExitCode -ne 0) { throw 'Claude canary call failed' }
        $parsed = ConvertFrom-ClaudeCliResult -Stdout $stdout.GetAwaiter().GetResult() -RequestedModel $Model
        if ($parsed.is_error) { throw 'Claude canary result reported error' }
        return $parsed.result
    } finally { if (-not $process.HasExited) { $process.Kill($true) }; $process.Dispose() }
}

function Invoke-RouterCanary {
    param([string[]]$Models,[ValidateSet('monthly','post-release','manual')][string]$Reason='manual',[scriptblock]$Invoker,[switch]$DryRun,[datetime]$Now=(Get-Date),[switch]$ExplicitModels)
    $scope = @(Get-CanaryScope -OnlyModels $Models -ExcludeFrontier:($Reason -ne 'manual' -and -not $ExplicitModels))
    $burn = Get-CanaryBurn -Scope $scope
    if ($DryRun) { return [pscustomobject]@{ dry_run=$true; scope=$scope; burn=$burn } }
    $state = Get-RouterStateDir
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $lockPath = Join-Path $state 'canary.lock'
    try { $lock = [IO.FileStream]::new($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose) }
    catch [IO.IOException] { throw 'CANARY_ALREADY_RUNNING' }
    try {
        $runDir = Join-Path $state ('canary/' + $Now.ToString('yyyyMMdd') + '-' + $Reason)
        [IO.Directory]::CreateDirectory($runDir) | Out-Null
        $results = [System.Collections.Generic.List[object]]::new()
        $outcomes = Join-Path $state 'outcomes.jsonl'
        foreach ($model in $scope) {
            if (@($model.tasks).Count -eq 0) { continue }
            foreach ($task in @($model.tasks) + @('pelican')) {
                $taskDir = Join-Path $PSScriptRoot ('tasks/' + $task)
                $prompt = [IO.File]::ReadAllText((Join-Path $taskDir 'prompt.md'))
                $runCount = if ($task -eq 'pelican') { 1 } else { $script:CanaryRuns }
                for ($run=1; $run -le $runCount; $run++) {
                    $answer = ''; $passed = $false; $errorText = $null
                    try {
                        $answer = if ($Invoker) { [string](& $Invoker $model.model $model.lane $task $prompt $run) } else { [string](Invoke-CanaryModel -Model $model.model -Lane $model.lane -Prompt $prompt) }
                        if ($task -eq 'pelican') {
                            $svg = Join-Path $runDir ($model.model + '-pelican.svg')
                            [IO.File]::WriteAllText($svg,$answer)
                        } else {
                            $answerFile = Join-Path $runDir ([guid]::NewGuid().ToString('N') + '.answer')
                            try {
                                [IO.File]::WriteAllText($answerFile,$answer)
                                $grade = & python (Join-Path $taskDir 'grader.py') $answerFile
                                $passed = $LASTEXITCODE -eq 0
                            } finally { Remove-Item -LiteralPath $answerFile -Force -ErrorAction SilentlyContinue }
                        }
                    } catch { $errorText = $_.Exception.Message }
                    if ($task -eq 'pelican') { continue }
                    $category = if ($task -like 'complex-coding-*') { 'complex-coding' } elseif ($task -like 'routine-coding-*') { 'routine-coding' } else { $task }
                    $row = [pscustomobject]@{ key="canary:$($Now.ToString('yyyyMMdd')):$Reason`:$($model.model):$task`:$run"; run_id="canary-$($Now.ToString('yyyyMMdd'))-$Reason"; repo='danny-skills'; at=$Now.ToUniversalTime().ToString('o'); lane=$model.lane; model=$model.model; category=$category; task=$task; attempt=1; pass=$passed; escalated=$false; failure_category=$(if ($errorText) { 'environment' } else { $null }); source='canary'; tier='canary' }
                    [IO.File]::AppendAllText($outcomes,($row | ConvertTo-Json -Compress) + "`n")
                    $results.Add([pscustomobject]@{ model=$model.model; task=$task; run=$run; pass=$passed; error=$errorText })
                }
            }
        }
        $baselinePath = Join-Path $state 'canary/baseline.json'
        $baseline = Read-RouterJsonObject -Path $baselinePath
        if (-not $baseline) { $baseline = [pscustomobject]@{} }
        $alerts = [System.Collections.Generic.List[object]]::new()
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('# Model router canary')
        $lines.Add('')
        $lines.Add("Estimated burn: $($burn.input_tokens) input + $($burn.output_tokens) output tokens; priced API equivalent `$$($burn.priced_usd). Unpriced: $($burn.unpriced -join ', ').")
        foreach ($model in $scope) {
            $rows = @($results | Where-Object model -eq $model.model)
            if (-not $rows.Count) { continue }
            $rate = @($rows | Where-Object pass).Count / $rows.Count
            $prior = $baseline.PSObject.Properties[[string]$model.model]
            if (-not $prior -and $rows.Count -eq (@($model.tasks).Count * $script:CanaryRuns) -and -not @($rows | Where-Object { $_.error }).Count) {
                $baseline | Add-Member -NotePropertyName $model.model -NotePropertyValue $rate
                $prior = $baseline.PSObject.Properties[[string]$model.model]
            }
            $baselineText = if ($prior) { "$([Math]::Round([double]$prior.Value*100,1))%" } else { 'pending complete run' }
            $lines.Add("- $($model.model): $([Math]::Round($rate*100,1))% pass; baseline $baselineText; [pelican]($($model.model)-pelican.svg)")
            if ($prior -and ([double]$prior.Value - $rate) -ge 0.15) { $alerts.Add([pscustomobject]@{ key="canary-drop:$($model.model):$($Now.ToString('yyyyMM'))"; message="Canary pass rate for $($model.model) fell from $($prior.Value) to $rate. Report: $runDir/report.md" }) }
        }
        [IO.File]::WriteAllText($baselinePath,($baseline | ConvertTo-Json -Depth 10))
        [IO.File]::WriteAllText((Join-Path $runDir 'results.json'),([pscustomobject]@{ reason=$Reason; scope=$scope; burn=$burn; results=@($results.ToArray()) } | ConvertTo-Json -Depth 15))
        $report = Join-Path $runDir 'report.md'
        [IO.File]::WriteAllLines($report,$lines)
        $alerts.Add([pscustomobject]@{ key="canary-complete:$($Now.ToString('yyyyMMdd'))"; message="Canary complete: $report" })
        if (-not $Invoker) { Send-RouterAlerts -Alerts @($alerts.ToArray()) | Out-Null }
        return [pscustomobject]@{ dry_run=$false; scope=$scope; burn=$burn; results=@($results.ToArray()); alerts=@($alerts.ToArray()); report=$report }
    } finally { $lock.Dispose() }
}

function Start-RouterCanaryDetached {
    param([Parameter(Mandatory)][string[]]$Models)
    $shim = 'D:\Claude\_system-tools\run-hidden\run-hidden.vbs'
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $wscript = (Get-Command wscript.exe -ErrorAction Stop).Source
    $file = Join-Path $env:TEMP ('router-canary-models-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($file,(ConvertTo-Json -InputObject @($Models) -Compress))
        $args = @($shim,$pwsh,$script:RouterCanaryScriptPath,'-Reason','post-release','-ModelsFile',$file)
        if ((Get-Variable RouterCanaryLauncher -Scope Script -ErrorAction SilentlyContinue) -and $script:RouterCanaryLauncher) { & $script:RouterCanaryLauncher $wscript $args | Out-Null }
        else { Start-Process -FilePath $wscript -ArgumentList @($args | ForEach-Object { '"' + ([string]$_).Replace('"','""') + '"' }) -WindowStyle Hidden | Out-Null }
        return [pscustomobject]@{ launched=$true; models=@($Models) }
    } catch {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($ModelsFile) {
        try { $Models = @([IO.File]::ReadAllText($ModelsFile) | ConvertFrom-Json) }
        finally { Remove-Item -LiteralPath $ModelsFile -Force -ErrorAction SilentlyContinue }
    }
    $result = Invoke-RouterCanary -Models $Models -Reason $Reason -DryRun:$DryRun -ExplicitModels:($PSBoundParameters.ContainsKey('Models') -and -not $ModelsFile)
    if ($Json) { $result | ConvertTo-Json -Depth 15 -Compress } else { $result }
}
