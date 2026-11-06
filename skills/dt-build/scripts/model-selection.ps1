if (-not (Get-Command Invoke-SecretRedaction -ErrorAction SilentlyContinue)) {
    $modelSelectionRepoRoot = & {
        $skillRoot = Split-Path -Parent $PSScriptRoot
        $original = (Resolve-Path -LiteralPath $skillRoot).Path
        $cursor = Get-Item -LiteralPath $original
        while ($null -ne $cursor) {
            $resolved = $null
            try { $resolved = $cursor.ResolveLinkTarget($true) } catch { }
            if ($resolved) {
                $suffix = [IO.Path]::GetRelativePath($cursor.FullName, $original)
                $skillRoot = if ($suffix -eq '.') { $resolved.FullName } else { Join-Path $resolved.FullName $suffix }
                break
            }
            $cursor = if ($cursor.PSObject.Properties['Parent']) { $cursor.Parent } else { $null }
        }
        Split-Path -Parent (Split-Path -Parent $skillRoot)
    }
    . (Join-Path $modelSelectionRepoRoot 'scripts/security/redact-secrets.ps1')
}
function Publish-DtJobModelSelection {
    param([string]$Line, [string]$Model, [string]$Vendor, [string]$Effort)
    if (-not $Line) { return }
    $Line = Invoke-SecretRedaction -Text $Line
    [Console]::Error.WriteLine($Line)
    if (-not $env:DT_JOB_DIR) { return }
    # A wrapper owns this sidecar only. Never write the runner's job record.
    $path = Join-Path $env:DT_JOB_DIR 'model-selection.json'
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $row = [ordered]@{ disclosure_line = $Line; model = $Model; vendor = $Vendor; effort = $Effort; selected_utc = [DateTime]::UtcNow.ToString('o'); wrapper_pid = $PID }
        [IO.File]::WriteAllText($temp, ($row | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $path, $true)
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Get-DtJobModelSelection {
    param([string]$RunFolder, [string]$JobId)
    $path = Join-Path $RunFolder "jobs/$JobId/model-selection.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Read-DtJobText -Path $path | ConvertFrom-Json)
}
