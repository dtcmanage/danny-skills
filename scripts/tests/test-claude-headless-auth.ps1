# Regression tests for scripts/claude-headless-auth.ps1.
#   pwsh -NoProfile -File scripts/tests/test-claude-headless-auth.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-headless-auth.ps1')
$failures = 0
function Assert { param([bool]$Condition, [string]$Name) if ($Condition) { "PASS: $Name" } else { "FAIL: $Name"; $script:failures++ } }
$root = Join-Path ([IO.Path]::GetTempPath()) ("claude-auth-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null
$saved = $env:DT_CLAUDE_TOKEN_FILE; $savedToken = $env:CLAUDE_CODE_OAUTH_TOKEN
try {
    Remove-Item Env:CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue
    $file = Join-Path $root 'secrets.env'
    Set-Content -LiteralPath $file -Value "CC_HOST_TODO_API_KEY=other`nCLAUDE_CODE_OAUTH_TOKEN=fixture-token-123`n"
    $env:DT_CLAUDE_TOKEN_FILE = $file
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $source = Set-ClaudeHeadlessAuth -StartInfo $psi
    Assert ($source -eq 'secrets-file' -and $psi.Environment['CLAUDE_CODE_OAUTH_TOKEN'] -eq 'fixture-token-123') 'stripped token is restored on the child from the secrets file'
    Assert (-not $psi.Environment.ContainsKey('CC_HOST_TODO_API_KEY') -or $psi.Environment['CC_HOST_TODO_API_KEY'] -ne 'other') 'other secrets in the file are not copied'
    Assert (-not ([string]$source).Contains('fixture-token')) 'return value never carries the token'
    Assert ([string]::IsNullOrEmpty($env:CLAUDE_CODE_OAUTH_TOKEN)) 'parent environment is untouched'
    $psi2 = [System.Diagnostics.ProcessStartInfo]::new(); $psi2.Environment['CLAUDE_CODE_OAUTH_TOKEN'] = 'inherited-token'
    Assert ((Set-ClaudeHeadlessAuth -StartInfo $psi2) -eq 'inherited' -and $psi2.Environment['CLAUDE_CODE_OAUTH_TOKEN'] -eq 'inherited-token') 'an inherited token wins'
    Set-Content -LiteralPath $file -Value 'CLAUDE_CODE_OAUTH_TOKEN="quoted-token"'
    $psi3 = [System.Diagnostics.ProcessStartInfo]::new()
    Assert ((Set-ClaudeHeadlessAuth -StartInfo $psi3) -eq 'secrets-file' -and $psi3.Environment['CLAUDE_CODE_OAUTH_TOKEN'] -eq 'quoted-token') 'quoted value is unquoted'
    $env:DT_CLAUDE_TOKEN_FILE = Join-Path $root 'missing.env'
    $psi4 = [System.Diagnostics.ProcessStartInfo]::new()
    Assert ((Set-ClaudeHeadlessAuth -StartInfo $psi4) -eq 'none' -and -not $psi4.Environment.ContainsKey('CLAUDE_CODE_OAUTH_TOKEN')) 'missing file leaves the child unchanged'
    Set-Content -LiteralPath (Join-Path $root 'empty.env') -Value 'CLAUDE_CODE_OAUTH_TOKEN='
    $env:DT_CLAUDE_TOKEN_FILE = Join-Path $root 'empty.env'
    Assert ((Set-ClaudeHeadlessAuth -StartInfo ([System.Diagnostics.ProcessStartInfo]::new())) -eq 'none') 'empty value is treated as none'
}
finally {
    $env:DT_CLAUDE_TOKEN_FILE = $saved
    if ($null -ne $savedToken) { $env:CLAUDE_CODE_OAUTH_TOKEN = $savedToken }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures) { "$failures failure(s)"; exit 1 }
'All claude-headless-auth tests passed.'
