function Publish-DtJobModelSelection {
    param([string]$Line, [string]$Model, [string]$Vendor, [string]$Effort)
    if (-not $Line) { return }
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
