# Dot-source from a router test, then call Enter-RouterTestCodexHome before its try block and
# Exit-RouterTestCodexHome in its finally block.
#
# Router picks check the Codex model catalog (CODEX_HOME\models_cache.json) and Codex usage (session logs). On a real
# machine several installed Codex clients rewrite that one shared catalog with different model lists (2026-09-30: the
# 0.159.2 CLI listed gpt-6.1-sol, the desktop app's 0.158.0 runtime did not), so tests that read it flipped between runs.
# This points both at fixtures: a fixed catalog, and an empty sessions folder unless the test already chose one.
# Claude credentials point to a missing fixture path unless the test already supplied an override.

function Enter-RouterTestCodexHome {
    $root = Join-Path $env:TEMP ('router-test-codex-home-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $slugs = @('gpt-6-astra', 'gpt-6.1-sol', 'gpt-6-sol', 'gpt-6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-5.5')
    $models = for ($i = 0; $i -lt $slugs.Count; $i++) { [pscustomobject]@{ slug = $slugs[$i]; visibility = 'list'; priority = $i + 1 } }
    $catalog = [pscustomobject]@{ fetched_at = 'fixture'; models = @($models) }
    [IO.File]::WriteAllText((Join-Path $root 'models_cache.json'), (ConvertTo-Json -InputObject $catalog -Depth 5), [Text.UTF8Encoding]::new($false))
    $saved = [pscustomobject]@{ root = $root; codex_home = $env:CODEX_HOME; sessions = $env:DT_MODEL_ROUTER_CODEX_SESSIONS; set_sessions = $false; claude_credentials = $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS; set_claude_credentials = $false }
    $env:CODEX_HOME = $root
    if (-not $env:DT_MODEL_ROUTER_CODEX_SESSIONS) {
        $sessions = Join-Path $root 'sessions'
        [IO.Directory]::CreateDirectory($sessions) | Out-Null
        $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $sessions
        $saved.set_sessions = $true
    }
    if (-not $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS) {
        $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $root 'missing-claude-credentials.json'
        $saved.set_claude_credentials = $true
    }
    return $saved
}

function Exit-RouterTestCodexHome {
    param([object]$Saved)
    if ($null -eq $Saved) { return }
    $env:CODEX_HOME = $Saved.codex_home
    if ($Saved.set_sessions) { $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $Saved.sessions }
    if ($Saved.set_claude_credentials) { $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $Saved.claude_credentials }
    Remove-Item -LiteralPath $Saved.root -Recurse -Force -ErrorAction SilentlyContinue
}
