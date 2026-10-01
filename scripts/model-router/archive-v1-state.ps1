param(
    [string]$StatePath,
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')][string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$Force,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')

$null = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
if (-not $StatePath) { $StatePath = Get-RouterStateDir }
$StatePath = [IO.Path]::GetFullPath($StatePath)
if (-not (Test-Path -LiteralPath $StatePath -PathType Container)) { throw "State folder does not exist: $StatePath" }
$archivePath = Join-Path $StatePath "_archive/v1-$Date"
if ((Test-Path -LiteralPath $archivePath) -and -not $Force) { throw "Archive already exists: $archivePath. Use -Force to overwrite." }
[IO.Directory]::CreateDirectory($archivePath) | Out-Null
$copied = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()
foreach ($name in @('router-table.json', 'drift-flags.json', 'profiles')) {
    $source = Join-Path $StatePath $name
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $archivePath -Recurse -Force
        $copied.Add($name)
    } else { $skipped.Add($name) }
}
$result = [pscustomobject]@{ archive_path = $archivePath; copied = @($copied.ToArray()); skipped = @($skipped.ToArray()) }
if ($Json) { $result | ConvertTo-Json -Depth 5 -Compress } else { $result }
