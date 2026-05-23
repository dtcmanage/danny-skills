param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [string[]]$RequiredEntitlements,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "SPAWN_PREFLIGHT_FAIL: manifest not found: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$errors = New-Object System.Collections.Generic.List[string]
$resolved = @()

foreach ($entitlement in $RequiredEntitlements) {
    if (-not ($manifest.PSObject.Properties.Name -contains $entitlement)) {
        $errors.Add("SPAWN_PREFLIGHT_FAIL: missing entitlement '$entitlement' in manifest")
        continue
    }

    $entry = $manifest.$entitlement
    $path = [string]$entry.path
    if (-not (Test-Path -LiteralPath $path)) {
        $errors.Add("SPAWN_PREFLIGHT_FAIL: entitlement '$entitlement' path missing: $path")
        continue
    }

    $actual = Get-FileSha256 -Path $path
    $expected = [string]$entry.file_sha256
    if ($actual -ne $expected) {
        $errors.Add("SPAWN_PREFLIGHT_FAIL: entitlement '$entitlement' hash mismatch expected=$expected actual=$actual")
        continue
    }

    $resolved += [pscustomobject]@{
        entitlement = $entitlement
        path = (Resolve-Path -LiteralPath $path).Path
        sha256 = $actual
    }
}

$result = [pscustomobject]@{
    pass = ($errors.Count -eq 0)
    resolved = $resolved
    errors = @($errors)
}

if (-not $result.pass) {
    if ($Json) {
        $result | ConvertTo-Json -Depth 6
        exit 1
    }
    throw (("Spawn preflight failed:`n- " + ($result.errors -join "`n- ")))
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else {
    Write-Output ("PASS: spawn preflight resolved {0} entitlement(s)" -f $resolved.Count)
}
