param(
    [Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Vendor,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Model,
    [ValidateSet('low','medium','high')][string]$Effort='low',
    [switch]$Live
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $Live){throw 'A real model call requires explicit -Live.'}
. (Join-Path $PSScriptRoot 'run-bench.ps1')
if(-not $Model){
    $entry=(Read-RouterRoster).roster.jobs.fast
    $slot=if(($entry.first -like 'claude-*') -eq ($Vendor -eq 'claude')){'first'}else{'backup'}
    $Model=[string]$entry.$slot
    if(-not $PSBoundParameters.ContainsKey('Effort')){
        $effortKey=$slot+'_effort'
        $Effort=[string]$entry.$effortKey
        if($Effort -notin @('low','medium','high')){throw 'Fast roster effort unavailable for transport smoke.'}
    }
}
$frontier=Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json
if(Test-RouterFrontierModel -Model $Model -Frontier $frontier){throw 'Transport smoke excludes frontier models.'}
if(($Vendor -eq 'codex' -and $Model -notmatch '^gpt-') -or ($Vendor -eq 'claude' -and $Model -notmatch '^claude-')){throw 'Vendor and model disagree.'}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutDir))
$schema=$null
if($Vendor -eq 'codex'){
    $cli=Get-Command codex -CommandType Application,ExternalScript -ErrorAction Stop | Select-Object -First 1
    $spec=Get-CodexProcessSpec -CodexPath $cli.Source
    $schemaCommand=@($spec.file)+@($spec.prefix_args)
    $schemaJson=ConvertTo-Json -InputObject $schemaCommand -Compress
    $schema=& python -B -c 'import json,sys;sys.path.insert(0,sys.argv[1]);from codex_appserver import schema_comparison;print(json.dumps(schema_comparison(json.loads(sys.argv[2]))))' $PSScriptRoot $schemaJson
    if($LASTEXITCODE -ne 0){throw 'Schema preflight failed before model call.'}
    [IO.File]::WriteAllText((Join-Path $OutDir 'protocol-schema.json'),[string]$schema)
}
$request=@{vendor=$Vendor;model=$Model;effort=$Effort;purpose='answer';prompt='Reply with exactly OK. Use no tools.'}
try{$response=Invoke-BenchCli -Request $request -TimeoutMs 120000}
catch{
    if($_.Exception.Data.Contains('bench_response')){$response=$_.Exception.Data['bench_response']}
    else{$response=@{status='unknown';detail='transport smoke failed'}}
}
# Persist only the transport's bounded safe diagnostics, never raw CLI output or metadata.
$diagnostics=if($response.ContainsKey('protocol_diagnostics') -and $response.protocol_diagnostics){$response.protocol_diagnostics}else{@{seen=@();rejected=@()}}
$events=@(Get-Content (Join-Path $PSScriptRoot 'appserver-methods.json') -Raw | ConvertFrom-Json)
$eventRecords=@(foreach($event in $events){@{method=$event;observation=$(if($event -in $diagnostics.seen){'seen'}else{'not-exercised'})}})
$category=$null
$detail=$null
$reason=$null
if($response.status -ne 'ok'){
    $category=if($response.ContainsKey('failure_category') -and $response.failure_category -in @('protocol','transport','environment','identity','quota','auth','unclassified')){$response.failure_category}else{'unclassified'}
    $detail=if($category -eq 'auth'){'Authentication failed; re-authenticate before rerunning'}elseif($response.ContainsKey('detail') -and $response.detail -ceq 'single-inference raw evidence missing or ambiguous'){$response.detail}else{'transport smoke failed'}
    if($diagnostics.ContainsKey('reason') -and $diagnostics.reason -cmatch '^(raw_item_invalid:(message|reasoning|additional_tools|function_call|custom_tool_call|OTHER)|response_count|answer_mismatch)$'){$reason=$diagnostics.reason}
}
$report=@{vendor=$Vendor;model=$Model;effort=$Effort;status=$response.status;failure_category=$category;detail=$detail;reason=$reason;events=$eventRecords;diagnostics=$diagnostics;acceptance='execution only; independent coordinator acceptance required'}
$reportPath=Join-Path $OutDir 'smoke-transport.json'
[IO.File]::WriteAllText($reportPath,($report | ConvertTo-Json -Depth 12))
$report | ConvertTo-Json -Depth 12
if($response.status -ne 'ok'){exit 1}
