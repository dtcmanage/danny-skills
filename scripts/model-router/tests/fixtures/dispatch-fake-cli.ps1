foreach ($name in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID')) { Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue }
if ($args -contains '--version') { 'router fake CLI'; exit 0 }
if ($args -contains 'debug') { Get-Content -LiteralPath (Join-Path $env:CODEX_HOME 'models_cache.json') -Raw; exit 0 }
$null = [Console]::In.ReadToEnd()
$vendor = if ($args -contains 'exec') { 'codex' } else { 'claude' }
[IO.File]::AppendAllText($env:M04_FAKE_ARGS, ($vendor + '|' + ($args -join '|') + "`n"))
if ($env:M04_FAKE_READER_SIGNAL) {
    [IO.File]::WriteAllText($env:M04_FAKE_READER_SIGNAL, 'ready')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath ($env:M04_FAKE_READER_SIGNAL + '.held'))) {
        if ($watch.Elapsed.TotalSeconds -gt 30) { throw 'Fake ledger reader failed to acquire handle' }
        Start-Sleep -Milliseconds 50
    }
}
$model = $args[[array]::IndexOf($args,'--model')+1]
if (($env:M04_FAKE_MODE -eq 'incident' -and $vendor -eq 'codex') -or ($env:M04_FAKE_MODE -eq 'claude-incident' -and $vendor -eq 'claude')) { [Console]::Error.WriteLine('fixture vendor server error'); exit 1 }
if ($env:M04_FAKE_MODE -eq 'unexplained') { [Console]::Error.WriteLine('fixture unexplained execution failure'); exit 1 }
$report = if ($env:M04_FAKE_REPORT) { [IO.File]::ReadAllText($env:M04_FAKE_REPORT) } else { 'OK' }
if ($vendor -eq 'claude') {
    $usage = @{}; $usage[$model] = @{inputTokens=3;outputTokens=4}
    if ($env:M04_FAKE_MODE -eq 'unknown-usage') { @{type='result';result=$report;is_error=$false} | ConvertTo-Json -Compress }
    else { @{type='result';result=$report;is_error=$false;modelUsage=$usage} | ConvertTo-Json -Compress -Depth 6 }
} else {
    $out = $args[[array]::IndexOf($args,'--output-last-message')+1]
    [IO.File]::WriteAllText($out,$report)
    if ($env:M04_FAKE_MODE -ne 'no-rollout') {
        $id = [guid]::NewGuid().ToString()
        $cwd = $args[[array]::IndexOf($args,'--cd')+1]
        $rollout = Join-Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS "rollout-2026-11-05T00-00-00-$id.jsonl"
        @(@{type='session_meta';payload=@{id=$id;cwd=$cwd}},@{type='turn_context';payload=@{model=$model}},@{type='event_msg';payload=@{type='token_count';info=@{total_token_usage=@{input_tokens=31;output_tokens=7}}}}) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 } | Set-Content -LiteralPath $rollout
        [Console]::Error.WriteLine("session id: $id")
    }
    'plain final message; unchanged exec stream'
}
