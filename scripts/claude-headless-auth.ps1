# Headless Claude sign-in for launched `claude -p` children (dot-source; functions only).
#
# Claude Code strips CLAUDE_CODE_OAUTH_TOKEN from every shell its tools start, so a coordinator or
# session that launches a Claude worker through its Bash tool hands that worker no token, and the
# worker falls back to the interactive login in .credentials.json, which expires and cannot refresh
# headless ("OAuth session expired and could not be refreshed"; run mst-20261122, 2026-11-23).
# Set-ClaudeHeadlessAuth puts the long-lived token on the child's ProcessStartInfo only: read from
# the secrets file Command Center v2 keeps (vault claude-oauth-token), never logged, never written to
# a job spec, run record or the parent environment.
#
# Source order: a token already on the StartInfo (inherited) wins; else DT_CLAUDE_TOKEN_FILE; else
# ~/.config/command-center-v2/secrets.env. Returns the source label only: inherited | secrets-file | none.

function Set-ClaudeHeadlessAuth {
    param([Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$StartInfo)
    $name = 'CLAUDE_CODE_OAUTH_TOKEN'
    if ($StartInfo.Environment.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace($StartInfo.Environment[$name])) {
        return 'inherited'
    }
    $file = if ($env:DT_CLAUDE_TOKEN_FILE) { $env:DT_CLAUDE_TOKEN_FILE } elseif ($HOME) { Join-Path $HOME '.config/command-center-v2/secrets.env' } else { $null }
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return 'none' }
    try { $lines = [System.IO.File]::ReadAllLines($file) } catch { return 'none' }
    foreach ($line in $lines) {
        if ($line -match '^\s*(?:export\s+)?CLAUDE_CODE_OAUTH_TOKEN\s*=\s*(.*?)\s*$') {
            $value = $Matches[1]
            if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            if ([string]::IsNullOrWhiteSpace($value)) { return 'none' }
            $StartInfo.Environment[$name] = $value
            return 'secrets-file'
        }
    }
    return 'none'
}
