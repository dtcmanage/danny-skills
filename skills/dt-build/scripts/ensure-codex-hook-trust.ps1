#Requires -Version 7.0
# Codex runs a hook only after it is trusted: config.toml must hold the hook's current hash under
# [hooks.state.'<key>']. A managed Codex coordinator gets the dt-build context hooks as session flags
# (-c hooks.PreToolUse=..., -c hooks.PostToolUse=...), which no person reviews in the Codex UI. This
# asks the Codex app server for those hooks' keys and hashes (hooks/list, with the same -c flags), and
# records each session-flag hook that is not yet trusted. Codex computes the hash, so nothing here
# reimplements its format. Other hooks are never touched. Prints one JSON result; never throws.
param(
    [Parameter(Mandatory)][string[]]$HookOverrides,
    [int]$TimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return (Join-Path $HOME '.codex')
}

function Get-CodexHookList {
    # The app server's hooks/list hooks, or a fixture path in DT_BUILD_CODEX_HOOK_LIST_JSON (tests).
    if ($env:DT_BUILD_CODEX_HOOK_LIST_JSON) {
        return @(([System.IO.File]::ReadAllText($env:DT_BUILD_CODEX_HOOK_LIST_JSON) | ConvertFrom-Json).hooks)
    }
    $codex = Get-Command codex -ErrorAction Stop | Select-Object -First 1
    $entry = Join-Path (Split-Path -Parent $codex.Source) 'node_modules/@openai/codex/bin/codex.js'
    if (-not (Test-Path -LiteralPath $entry)) { throw "codex entry script not found at $entry" }
    $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Command node -ErrorAction Stop | Select-Object -First 1).Source)
    $info.ArgumentList.Add($entry)
    $info.ArgumentList.Add('app-server')
    foreach ($override in $HookOverrides) { $info.ArgumentList.Add('-c'); $info.ArgumentList.Add($override) }
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($info)
    try {
        $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"dt-build","version":"1"}}}')
        $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"initialized"}')
        $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"hooks/list","params":{}}')
        $proc.StandardInput.Flush()
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        while ([DateTime]::UtcNow -lt $deadline) {
            $read = $proc.StandardOutput.ReadLineAsync()
            if (-not $read.Wait([TimeSpan]::FromSeconds([math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalSeconds)))) { break }
            if ($null -eq $read.Result) { break }
            try { $message = $read.Result | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($message.PSObject.Properties['id'] -and $message.id -eq 2) {
                if ($message.PSObject.Properties['error']) { throw "hooks/list failed: $($message.error | ConvertTo-Json -Compress)" }
                return @($message.result.data | ForEach-Object { @($_.hooks) })
            }
        }
        throw "hooks/list gave no answer within $TimeoutSec s"
    }
    finally {
        if (-not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
        $proc.Dispose()
    }
}

function Set-CodexHookTrust {
    # Writes trusted_hash for one hook key into config.toml: replaces the value under an existing table
    # for the key, or appends the table. The write is atomic and retried while Codex holds the file.
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Hash)
    if ($Key.Contains("'") -or $Hash -notmatch '^sha256:[0-9a-f]{64}$') { throw "unexpected hook key or hash: $Key $Hash" }
    $header = "[hooks.state.'$Key']"
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $text = if (Test-Path -LiteralPath $ConfigPath) { [System.IO.File]::ReadAllText($ConfigPath) } else { '' }
            $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
            $lines = [System.Collections.Generic.List[string]]::new()
            if ($text) { $lines.AddRange([string[]]($text -split '\r?\n')) }
            $at = $lines.IndexOf($header)
            if ($at -ge 0) {
                $end = $at + 1
                while ($end -lt $lines.Count -and -not $lines[$end].TrimStart().StartsWith('[')) { $end++ }
                $done = $false
                for ($i = $at + 1; $i -lt $end; $i++) {
                    if ($lines[$i] -match '^\s*trusted_hash\s*=') { $lines[$i] = "trusted_hash = `"$Hash`""; $done = $true; break }
                }
                if (-not $done) { $lines.Insert($at + 1, "trusted_hash = `"$Hash`"") }
                $out = $lines -join $newline
            }
            else {
                $out = $text.TrimEnd("`r", "`n") + $newline + $newline + $header + $newline + "trusted_hash = `"$Hash`"" + $newline
            }
            $tmp = "$ConfigPath.dt-build-$PID.tmp"
            [System.IO.File]::WriteAllText($tmp, $out, [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
            return
        }
        catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
}

$result = [ordered]@{ status = 'ok'; trusted = @(); already_trusted = @(); error = $null }
try {
    $hooks = @(Get-CodexHookList | Where-Object { $_.source -eq 'sessionFlags' })
    if ($hooks.Count -eq 0) { throw 'hooks/list shows no session-flag hooks; the -c hook overrides were not applied' }
    $configPath = Join-Path (Get-CodexHome) 'config.toml'
    foreach ($hook in $hooks) {
        if ($hook.trustStatus -eq 'trusted') { $result.already_trusted += [string]$hook.key; continue }
        Set-CodexHookTrust -ConfigPath $configPath -Key ([string]$hook.key) -Hash ([string]$hook.currentHash)
        $result.trusted += [string]$hook.key
    }
}
catch {
    $result.status = 'failed'
    $result.error = [string]$_.Exception.Message
}
$result | ConvertTo-Json -Depth 4 -Compress
