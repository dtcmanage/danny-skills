# Deterministic CLI fixture: no model, network, credentials or background workers.
if ($args -contains '--version') { 'read-worker fixture'; exit 0 }
if ($args -contains 'debug') { Get-Content -LiteralPath (Join-Path $env:CODEX_HOME 'models_cache.json') -Raw; exit 0 }
$prompt = [Console]::In.ReadToEnd()
$output = [regex]::Match($prompt, '(?m)^READ_EXTRACT_OUTPUT_PATH: (.+)$').Groups[1].Value.Trim()
if (-not $output) { throw 'fixture requires declared output' }
$vendor = if ($args -contains 'exec') { 'codex' } else { 'claude' }
$mode = $env:AI9_CASE
[IO.File]::AppendAllText($env:AI9_LAUNCHES, "$vendor $mode`n")
function Frame($Value) { [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 30 -Compress)); [Console]::Out.Flush(); Start-Sleep -Milliseconds 40 }
function Assistant([string]$Id, [long]$Tokens = 5, [object[]]$Content = @()) {
    Frame @{type='assistant';message=@{id=$Id;model='fixture-actual';usage=@{input_tokens=$Tokens};content=$Content}}
}
function WriteFrame([string]$Id,[string[]]$Paths) {
    if ($vendor -eq 'claude') {
        Assistant $Id 5 @(@{type='tool_use';id=$Id;name='Write';input=@{file_path=$Paths[0]}})
        Frame @{type='user';message=@{content=@(@{type='tool_result';tool_use_id=$Id;content='written';is_error=$false})}}
    } else {
        Frame @{type='item.completed';item=@{id=$Id;type='file_change';status='completed';changes=@($Paths | ForEach-Object { @{path=$_;kind='update'} })}}
    }
}
$sessionId = [guid]::NewGuid().ToString()
if ($vendor -eq 'codex') { Frame @{type='thread.started';thread_id=$sessionId}; Frame @{type='turn.started'} }
if ($mode -eq 'deadline') { Start-Sleep -Seconds 20; exit 0 }
if ($mode -notin @('no-output','stale','empty')) { [IO.File]::WriteAllText($output, "source.md:3: exact retained fact`n") }
if ($mode -eq 'empty') { [IO.File]::WriteAllText($output, '') }
switch ($mode) {
    'tool-cap' {
        foreach ($id in @('tool1','tool2','tool3')) {
            if ($vendor -eq 'claude') { Assistant $id 5 @(@{type='tool_use';id=$id;name='Read';input=@{file_path='source.md'}}) }
            else { Frame @{type='item.started';item=@{id=$id;type='command_execution';command='cat source.md'}} }
        }
        Start-Sleep -Seconds 20
    }
    'turn-cap' {
        if ($vendor -eq 'claude') { Assistant 'one'; Assistant 'two' }
        else { Frame @{type='turn.started'} }
        Start-Sleep -Seconds 20
    }
    'input-cap' {
        if ($vendor -eq 'claude') { Assistant 'usage' 130000 }
        else { Frame @{type='turn.completed';usage=@{input_tokens=130000;output_tokens=1}} }
        Start-Sleep -Seconds 20
    }
    'live-input-cap' {
        if ($vendor -eq 'claude') { Assistant 'usage' 130000 }
        else {
            $rollout = Join-Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS ("rollout-fixture-$sessionId.jsonl")
            @(@{type='session_meta';payload=@{id=$sessionId;cwd=(Get-Location).Path}},@{type='turn_context';payload=@{model='fixture-live-model'}},@{type='event_msg';payload=@{type='token_count';info=@{total_token_usage=@{input_tokens=130000;output_tokens=1}}}}) | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress } | Set-Content $rollout
        }
        Start-Sleep -Seconds 20
    }
    'reedit' { WriteFrame 'write1' @($output); [IO.File]::AppendAllText($output, 'second retained line'); WriteFrame 'write2' @($output); Start-Sleep -Seconds 20 }
    'multi-file' {
        if ($vendor -eq 'claude') { WriteFrame 'write1' @($output); WriteFrame 'other' @('other.md'); WriteFrame 'write2' @($output) }
        else { WriteFrame 'write1' @($output); WriteFrame 'other' @($output,'other.md'); WriteFrame 'write2' @($output) }
    }
    'read-between' {
        WriteFrame 'write1' @($output)
        if ($vendor -eq 'claude') { Assistant 'read' 5 @(@{type='tool_use';id='read';name='Read';input=@{file_path='source.md'}}) }
        else { Frame @{type='item.completed';item=@{id='read';type='command_execution';status='completed';command='cat source.md'}} }
        WriteFrame 'write2' @($output)
    }
    'malformed' { [Console]::Out.WriteLine('not json') }
    'failure' { exit 1 }
    'incomplete' { exit 0 }
}
if ($vendor -eq 'claude') { Frame @{type='result';result='FINAL STDOUT MUST NOT REPLACE THE EXTRACT';is_error=$false} }
else {
    Frame @{type='turn.completed';usage=@{input_tokens=20;output_tokens=3}}
    $last = $args[[array]::IndexOf($args,'--output-last-message')+1]
    [IO.File]::WriteAllText($last, 'FINAL STDOUT MUST NOT REPLACE THE EXTRACT')
}
