$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../bench/run-bench.ps1')
$script:checks = 0
function Check($Condition, $Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
$root = Join-Path ([IO.Path]::GetTempPath()) ('bench-cache-duration-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$fake = Join-Path $root 'claude.ps1'
'[Console]::WriteLine($env:BENCH_DURATION_DOC)' | Set-Content $fake
$prior = $env:BENCH_DURATION_DOC
$base = @{input_tokens=2;output_tokens=3;cache_read_input_tokens=4;cache_creation_input_tokens=10}
$request = @{vendor='claude';model='claude-fable-5-1';effort='high';prompt='Synthetic usage fixture'}
function Invoke-UsageFixture($Usage) {
    $env:BENCH_DURATION_DOC = @{result='synthetic answer';modelUsage=@{'claude-fable-5-1'=@{inputTokens=2;outputTokens=3}};usage=$Usage} | ConvertTo-Json -Depth 10 -Compress
    return Invoke-BenchCli -Request $request -ClaudeResolver {$fake}
}
try {
    foreach ($pair in @(@(10,0),@(0,10),@(3,7),@(0,0))) {
        $u = @{} + $base
        $u.cache_creation_input_tokens = $pair[0] + $pair[1]
        $u.cache_creation = @{ephemeral_5m_input_tokens=$pair[0];ephemeral_1h_input_tokens=$pair[1]}
        $result = Invoke-UsageFixture $u
        Check ($result.status -eq 'ok' -and $null -ne $result.usage) 'Valid duration fixture rejected'
        Check ($result.usage.cache_write_5m -eq $pair[0] -and $result.usage.cache_write_1h -eq $pair[1]) 'Duration buckets changed'
        Check (-not $result.usage.ContainsKey('cache_write')) 'Aggregate double-counted beside durations'
    }
    foreach ($total in @(0,10)) {
        $u = @{} + $base; $u.cache_creation_input_tokens = $total
        $result = Invoke-UsageFixture $u
        Check ($result.usage.cache_write -eq $total) 'Unknown duration aggregate not preserved'
        Check (-not $result.usage.ContainsKey('cache_write_5m') -and -not $result.usage.ContainsKey('cache_write_1h')) 'Missing duration guessed'
    }
    foreach ($bad in @($null, 'bad', @(), @{}, @{ephemeral_5m_input_tokens=3},
        @{ephemeral_5m_input_tokens=3;ephemeral_1h_input_tokens=6},
        @{ephemeral_5m_input_tokens=3;ephemeral_1h_input_tokens=8},
        @{ephemeral_5m_input_tokens=-1;ephemeral_1h_input_tokens=11},
        @{ephemeral_5m_input_tokens=$true;ephemeral_1h_input_tokens=9},
        @{ephemeral_5m_input_tokens=3.0;ephemeral_1h_input_tokens=7},
        @{ephemeral_5m_input_tokens='3';ephemeral_1h_input_tokens=7},
        @{ephemeral_5m_input_tokens=3;ephemeral_1h_input_tokens=$null})) {
        $u = @{} + $base; $u.cache_creation = $bad
        $result = Invoke-UsageFixture $u
        Check ($result.status -eq 'ok' -and $null -eq $result.usage) 'Malformed or inconsistent split was priced'
    }
    Check ($null -eq (ConvertFrom-BenchClaudeUsage @{cache_creation_input_tokens=0})) 'Missing base counts invented'
    Write-Output "SUMMARY: $script:checks passed; 0 failed"
} finally {
    $env:BENCH_DURATION_DOC = $prior
    # Temporary fixture content is under this verified unique root only.
    $resolved = [IO.Path]::GetFullPath($root)
    if ((Split-Path $resolved -Leaf) -notlike 'bench-cache-duration-*') { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
