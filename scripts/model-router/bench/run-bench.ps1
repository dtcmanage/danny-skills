param([string[]]$Jobs, [string[]]$Models,
    [ValidateSet('new-model','research','drift','manual')][string]$Trigger='manual',
    [string]$StateDir, [switch]$NoAlerts, [switch]$Json,
    [scriptblock]$Limits)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:BenchRoot=$PSScriptRoot
. (Join-Path $PSScriptRoot '../vendor-limits.ps1')
. (Join-Path $PSScriptRoot '../../invoke-codex-process.ps1')
. (Join-Path $PSScriptRoot '../../claude-cli-result.ps1')
. (Join-Path $PSScriptRoot '../../wrap-prompt-envelope.ps1')
. (Join-Path $PSScriptRoot '../../security/redact-secrets.ps1')

function Get-BenchErrorDetail {
    param([string]$Stdout, [string]$Stderr)
    # Select diagnostic fields; never persist the CLI's config/credential objects.
    try {
        $doc=$Stdout | ConvertFrom-Json -AsHashtable
        $selected=@{}
        foreach($key in @('result','message','error','errors','reset_at','resets_at')) {
            if($doc.ContainsKey($key)){$selected[$key]=$doc[$key]}
        }
        $Stdout=$selected | ConvertTo-Json -Depth 10 -Compress
    } catch { }
    $safe=Invoke-SecretRedaction -Text ($Stdout+"`n"+$Stderr)
    $safe=[regex]::Replace($safe, '(?i)(["'']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|authorization)["'']?\s*[:=]\s*)["'']?[^\s,"''}]+', '$1[REDACTED-SECRET]')
    return $safe
}

function ConvertFrom-BenchClaudeUsage {
    param($Usage)
    if ($Usage -isnot [System.Collections.IDictionary]) { return $null }
    foreach ($key in @('input_tokens','output_tokens','cache_read_input_tokens','cache_creation_input_tokens')) {
        if (-not $Usage.Contains($key) -or ($Usage[$key] -isnot [long] -and $Usage[$key] -isnot [int]) -or $Usage[$key] -lt 0) { return $null }
    }
    $normalized = @{input=$Usage.input_tokens;output=$Usage.output_tokens;cache_read=$Usage.cache_read_input_tokens}
    if (-not $Usage.Contains('cache_creation')) {
        # Aggregate-only writes have unknown duration, never an assumed 5m rate.
        $normalized.cache_write = $Usage.cache_creation_input_tokens
        return $normalized
    }
    $split = $Usage.cache_creation
    if ($split -isnot [System.Collections.IDictionary]) { return $null }
    foreach ($key in @('ephemeral_5m_input_tokens','ephemeral_1h_input_tokens')) {
        if (-not $split.Contains($key) -or ($split[$key] -isnot [long] -and $split[$key] -isnot [int]) -or $split[$key] -lt 0) { return $null }
    }
    if ([decimal]$split.ephemeral_5m_input_tokens + [decimal]$split.ephemeral_1h_input_tokens -ne [decimal]$Usage.cache_creation_input_tokens) { return $null }
    $normalized.cache_write_5m = $split.ephemeral_5m_input_tokens
    $normalized.cache_write_1h = $split.ephemeral_1h_input_tokens
    return $normalized
}

function Invoke-BenchCli {
    param($Request, [int]$TimeoutMs=120000,
        [scriptblock]$ClaudeResolver, [scriptblock]$CodexCommandResolver)
    $work=Join-Path ([IO.Path]::GetTempPath()) ('router-bench-call-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    try {
        [IO.File]::WriteAllText((Join-Path $work 'prompt.txt'), [string]$Request.prompt)
        if ($Request.vendor -eq 'codex') {
            if($CodexCommandResolver){$command=@(& $CodexCommandResolver)}
            else {
                # Follow the active PATH CLI; npm's entrypoint owns platform selection.
                # Stale package siblings must never participate in discovery.
                $cli=Get-Command codex -CommandType Application,ExternalScript -ErrorAction Stop | Select-Object -First 1
                $spec=Get-CodexProcessSpec -CodexPath $cli.Source
                $command=@($spec.file)+@($spec.prefix_args)
            }
            $psi=[Diagnostics.ProcessStartInfo]::new()
            $psi.FileName=(Get-Command python -ErrorAction Stop).Source
            $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
            $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
            [void]$psi.ArgumentList.Add((Join-Path $script:BenchRoot 'codex_appserver.py'))
            $process=[Diagnostics.Process]::Start($psi)
            try {
                $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
                $payload=@{command=$command;request=$Request;cwd=$work;timeout_ms=$TimeoutMs}|ConvertTo-Json -Depth 12 -Compress
                if([Text.Encoding]::UTF8.GetByteCount($payload) -gt 1048576){throw 'Codex stdin message limit'}
                $write=$process.StandardInput.WriteLineAsync($payload)
                if(-not $write.Wait([Math]::Min(5000,$TimeoutMs))){throw 'Codex stdin timeout'}
                $process.StandardInput.Close()
                if(-not $process.WaitForExit($TimeoutMs+12000)){throw 'Codex transport timeout'}
                if(-not $output.Wait(1000) -or $process.ExitCode -ne 0){throw 'Codex transport failed'}
                return ($output.GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable)
            } finally {if(-not $process.HasExited){$process.Kill($true)};$process.Dispose()}
        }

        if($ClaudeResolver){$cli=& $ClaudeResolver}
        else{$cli=(Get-Command claude.exe,claude.ps1,claude.cmd,claude -ErrorAction SilentlyContinue | Select-Object -First 1).Source}
        if(-not $cli){throw 'Claude CLI missing'}
        $args=@('-p','--model',$Request.model,'--effort',$Request.effort,'--output-format','json','--no-session-persistence','--strict-mcp-config','--tools','')
        $psi=[Diagnostics.ProcessStartInfo]::new()
        if([IO.Path]::GetExtension($cli) -eq '.ps1'){$psi.FileName=(Get-Command pwsh).Source;$args=@('-NoProfile','-File',$cli)+$args}
        elseif([IO.Path]::GetExtension($cli) -eq '.cmd') {throw 'Claude native executable required for bounded dispatch; cmd shim unsupported'}
        else{$psi.FileName=$cli}
        $psi.WorkingDirectory=$work;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        foreach($arg in $args){[void]$psi.ArgumentList.Add([string]$arg)}
        $process=[Diagnostics.Process]::Start($psi)
        try {
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            $write=$process.StandardInput.WriteAsync([string]$Request.prompt)
            if(-not $write.Wait(5000)){throw 'Claude stdin timeout'}
            $process.StandardInput.Close()
            if(-not $process.WaitForExit($TimeoutMs)){throw 'Claude timeout'}
            if(-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)){throw 'Claude output timeout'}
            $raw=$stdout.GetAwaiter().GetResult()
            $detail=Get-BenchErrorDetail -Stdout $raw -Stderr $stderr.GetAwaiter().GetResult()
            $doc=$null
            try {$doc=$raw | ConvertFrom-Json -AsHashtable} catch { }
            if($process.ExitCode -ne 0 -or ($doc -and $doc.ContainsKey('is_error') -and $doc.is_error)) {
                $identity=''
                if($doc -and $doc.ContainsKey('modelUsage') -and $doc.modelUsage.Count -gt 0 -and @($doc.modelUsage.Keys | Where-Object {$_ -cne $Request.model}).Count) {
                    $identity='Claude model changed during comparison. '
                }
                throw ($identity+$detail)
            }
            $parsed=ConvertFrom-ClaudeCliResult -Stdout $raw -RequestedModel $Request.model
            if($parsed.resolved_model -cne $Request.model){throw 'Claude model changed during comparison'}
            $doc=$raw | ConvertFrom-Json -AsHashtable
            $usage=$null
            if($doc.ContainsKey('usage')) {
                $usage=ConvertFrom-BenchClaudeUsage $doc.usage
            }
            return @{status='ok';answer=$parsed.result;resolved_model=$parsed.resolved_model;usage=$usage;cli=$cli;arguments=$args;tools='disabled';raw=$doc}
        } finally {if(-not $process.HasExited){$process.Kill($true)};$process.Dispose()}
    } finally {Remove-CodexTempDirectory -Path $work -ExpectedLeafPrefix 'router-bench-call-'}
}

function Invoke-RouterBench {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('fast','coder','deep-thinker','writer','illustrator')][string]$Job,
        [Parameter(Mandatory)][string]$Candidate,[Parameter(Mandatory)][string]$Incumbent,
        [ValidateSet('new-model','research','drift','manual')][string]$Trigger='manual',
        [string]$StateDir=(Get-RouterStateDir),[string]$Tasks=(Join-Path $script:BenchRoot 'tasks'),
        [string]$ConfigPath=(Join-Path $script:BenchRoot 'bench-config.json'),
        [ValidateSet('low','medium','high')][string]$EffortOverride,
        [scriptblock]$CliInvoker,[scriptblock]$Limits,[scriptblock]$Diagnosis,
        [scriptblock]$Envelope,[scriptblock]$Outcome,[switch]$NoAlerts,
        [int]$TimeoutMs=120000,[double]$GraderTimeout=30)
    # Bind all shared state readers/diagnosis to the explicit router root.
    Assert-RouterWindowsOwner -Action 'Benchmark execution'
    # Load proposal dependencies before binding explicit state readers locally.
    if ($Trigger -eq 'manual') { . (Join-Path $script:BenchRoot '../build-roster.ps1') }
    $benchStateRoot=[IO.Path]::GetFullPath($StateDir)
    function Get-RouterStateDir { return $benchStateRoot }
    function Get-RouterStatePath { param([string]$Platform) return $benchStateRoot }
    [void][IO.Directory]::CreateDirectory($benchStateRoot)
    $frontier=Get-Content (Join-Path $script:BenchRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json
    foreach($model in @($Candidate,$Incumbent)) {
        if($Trigger -ne 'manual' -and (Test-RouterFrontierModel -Model $model -Frontier $frontier)){throw 'Frontier candidates require manual named invocation'}
    }
    $read=Read-RouterRoster
    $effort=if($Job -eq 'illustrator'){$null}elseif($EffortOverride){$EffortOverride}else{$read.roster.jobs.$Job.first_effort}
    if (-not $PSBoundParameters.ContainsKey('ConfigPath')) {
        $catalogConfig = Join-Path $benchStateRoot 'bench/judge-config.json'
        if (Test-Path -LiteralPath $catalogConfig) { $ConfigPath = $catalogConfig }
    }
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    # Legacy persisted catalogs predate fixed judge effort. Fill only the missing
    # field from the shipped default; explicit config inputs still validate strictly.
    if (-not $PSBoundParameters.ContainsKey('ConfigPath') -and -not $config.ContainsKey('judge_effort')) {
        $config.judge_effort = (Get-Content (Join-Path $script:BenchRoot 'bench-config.json') -Raw | ConvertFrom-Json).judge_effort
    }
    if(-not $CliInvoker){$CliInvoker={param($r) Invoke-BenchCli -Request $r -TimeoutMs $TimeoutMs}}
    if(-not $Limits){$Limits={param($v) $u=if($v -eq 'claude'){Get-RouterClaudeUsage}else{Get-RouterCodexUsage}; @{blocked=(Get-RouterVendorBlocked -Vendor $v);usage=$u}}}
    if(-not $Diagnosis){$Diagnosis={param($v,$e) Resolve-RouterDispatchFailure -Vendor $v -ErrorText $e}}
    if(-not $Envelope){$Envelope={param($a) New-PromptEnvelope -Label 'BENCH ANSWER EVIDENCE' -Content $a}}
    if(-not $Outcome){$Outcome={param($r) Add-RouterOutcome -Row $r -StateDir $benchStateRoot}}
    $arguments=@{job=$Job;candidate=$Candidate;incumbent=$Incumbent;trigger=$Trigger;effort=$effort;
        state_dir=$benchStateRoot;tasks=[IO.Path]::GetFullPath($Tasks);grader_timeout=$GraderTimeout;
        config=$config;
        prices=(Get-Content (Join-Path $script:BenchRoot '../../../references/model-router/api-prices.json') -Raw | ConvertFrom-Json -AsHashtable)}
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=(Get-Command python -ErrorAction Stop).Source
    $psi.WorkingDirectory=$benchStateRoot;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.Environment['PYTHONDONTWRITEBYTECODE']='1'
    [void]$psi.ArgumentList.Add((Join-Path $script:BenchRoot 'bench_engine.py'))
    $process=[Diagnostics.Process]::Start($psi)
    $errors=$process.StandardError.ReadToEndAsync()
    try {
        $process.StandardInput.WriteLine(($arguments | ConvertTo-Json -Depth 30 -Compress));$process.StandardInput.Flush()
        while($true){
            $pending=$process.StandardOutput.ReadLineAsync()
            if(-not $pending.Wait([Math]::Max(60000,$TimeoutMs+10000))){throw 'Bench IPC timeout'}
            $line=$pending.GetAwaiter().GetResult()
            if($null -eq $line){throw "Bench engine ended: $($errors.GetAwaiter().GetResult())"}
            $message=$line | ConvertFrom-Json -AsHashtable
            if($message.operation -eq 'result'){
                $result = [pscustomobject]$message.payload
                if ($Trigger -eq 'manual') {
                    $request = [pscustomobject]@{job=$Job;candidate=$Candidate;incumbent=$Incumbent;effort=$effort}
                    Use-RouterOutcomeMutex -StateDir $benchStateRoot -Action { Save-RouterEffortProposal $request $result } | Out-Null
                    if (-not $NoAlerts) { Send-RouterEffortAlerts }
                }
                return $result
            }
            try {
                $value=switch($message.operation){
                    'limits' {
                        $reading=& $Limits $message.payload
                        if(Get-RouterVendorBlocked -Vendor $message.payload){$reading.blocked=$true}
                        $reading
                    }
                    'envelope' { & $Envelope $message.payload }
                    'outcome' { $null=& $Outcome $message.payload; $null }
                    'dispatch' {
                        $r=$message.payload
                        try { $response=& $CliInvoker $r; if($null -eq $response){throw 'Empty dispatch response'} }
                        catch { $response=@{status='unknown';failure_category='environment';detail=$_.Exception.Message} }
                        $response=$response | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json -AsHashtable
                        if($response.status -ne 'ok'){
                            $response.detail=Get-BenchErrorDetail -Stdout ([string]$response.detail) -Stderr ''
                            $refusal=Test-RouterLimitRefusal -Vendor $r.vendor -Text $response.detail
                            if($refusal.refused){
                                $blockArgs=@{Vendor=$r.vendor;Reason='quota_refusal'}
                                if($refusal.reset_at_utc){$blockArgs.ResetAtUtc=[datetimeoffset]$refusal.reset_at_utc}
                                $null=Add-RouterVendorBlock @blockArgs
                            }
                            $response.diagnosis=& $Diagnosis $r.vendor ([string]$response.detail)
                        }
                        try {$response.quota_after=& $Limits $r.vendor} catch {$response.quota_after=@{measurement='unavailable';detail=$_.Exception.Message}}
                        $response
                    }
                    default {throw 'Unknown IPC operation'}
                }
                $reply=@{value=$value}
            } catch {$reply=@{error=$_.Exception.Message}}
            $process.StandardInput.WriteLine(($reply | ConvertTo-Json -Depth 40 -Compress));$process.StandardInput.Flush()
        }
    } finally {if(-not $process.HasExited){$process.Kill($true)};$process.Dispose()}
}

if($MyInvocation.InvocationName -ne '.') {
    Assert-RouterWindowsOwner -Action 'Benchmark execution'
    if(-not $StateDir){$StateDir=Get-RouterStateDir}
    $script:cliBenchStateRoot=[IO.Path]::GetFullPath($StateDir)
    function Get-RouterStateDir {return $script:cliBenchStateRoot}
    function Get-RouterStatePath {param([string]$Platform) return $script:cliBenchStateRoot}
    $read=Read-RouterRoster
    if(-not $Jobs){$Jobs=Get-RouterJobs}
    $results=foreach($job in $Jobs){
        $entry=$read.roster.jobs.$job
        $candidates=if($Models){$Models}else{@($entry.first)}
        foreach($model in $candidates){Invoke-RouterBench -Job $job -Candidate $model -Incumbent $entry.first -Trigger $Trigger -StateDir $StateDir -Limits $Limits -NoAlerts:$NoAlerts}
    }
    if($Json){$results | ConvertTo-Json -Depth 40}else{$results}
}
