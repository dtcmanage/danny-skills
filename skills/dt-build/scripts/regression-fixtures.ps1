# Failed runs retain their fixture tree for diagnosis; expire only this suite's
# GUID-named directories after seven days. Never follow directory links.
function Remove-StaleDtRegressionFixtures {
    param([Parameter(Mandatory)][string]$TempDirectory)
    $cutoff = [DateTime]::UtcNow.AddDays(-7)
    Get-ChildItem -LiteralPath $TempDirectory -Directory -Filter 'dt-build-regressions-*' |
        Where-Object {
            $_.Name -cmatch '^dt-build-regressions-[0-9a-f]{32}$' -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            $_.LastWriteTimeUtc -lt $cutoff
        } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
}
