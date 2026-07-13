param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [string[]]$RequiredEntitlements,

    [Parameter(Mandatory)]
    [string]$RunId,

    [Parameter(Mandatory)]
    [string]$ChunkId,

    [Parameter(Mandatory)]
    [ValidateRange(1, 2)]
    [int]$Attempt,

    [string]$PreamblePath = "",
    [string]$PreambleText = "",
    [string]$BriefPath = "",
    [string]$BriefText = "",

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-SkillRepoRoot {
    $scriptPath = $script:PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = $PSCommandPath
    }
    $scriptDir = Split-Path -Parent $scriptPath
    $skillRoot = Split-Path -Parent $scriptDir
    $original = (Resolve-Path -LiteralPath $skillRoot).Path
    $cursor = Get-Item -LiteralPath $original
    while ($null -ne $cursor) {
        $resolved = $null
        try { $resolved = $cursor.ResolveLinkTarget($true) } catch { }
        if ($null -ne $resolved) {
            $suffix = [System.IO.Path]::GetRelativePath($cursor.FullName, $original)
            $skillRoot = if ($suffix -eq '.') { $resolved.FullName } else { Join-Path $resolved.FullName $suffix }
            break
        }
        $cursor = $cursor.Parent
    }
    return (Split-Path -Parent (Split-Path -Parent $skillRoot))
}

function Find-ByteSequence {
    param(
        [Parameter(Mandatory)][byte[]]$Buffer,
        [Parameter(Mandatory)][byte[]]$Needle,
        [int]$StartIndex = 0
    )
    if ($Needle.Length -eq 0) { return -1 }
    for ($i = $StartIndex; $i -le ($Buffer.Length - $Needle.Length); $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Buffer[$i + $j] -ne $Needle[$j]) {
                $match = $false
                break
            }
        }
        if ($match) { return $i }
    }
    return -1
}

function Get-Sha256HexFromBytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ReferencePackPayloadBytes {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $marker = [System.Text.Encoding]::UTF8.GetBytes("=== REFERENCE PACK PAYLOAD ===")
    $markerIndex = Find-ByteSequence -Buffer $bytes -Needle $marker
    if ($markerIndex -lt 0) {
        throw "ASSEMBLE_FAIL: payload marker missing in reference-pack file: $Path"
    }

    $afterMarker = $markerIndex + $marker.Length
    $lineEnd = -1
    for ($i = $afterMarker; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A) {
            $lineEnd = $i
            break
        }
    }
    if ($lineEnd -lt 0) {
        throw "ASSEMBLE_FAIL: payload marker line has no LF terminator: $Path"
    }

    $payloadStart = $lineEnd + 1
    if ($payloadStart -ge $bytes.Length) {
        return [byte[]]@()
    }

    $len = $bytes.Length - $payloadStart
    $payload = New-Object byte[] $len
    [System.Array]::Copy($bytes, $payloadStart, $payload, 0, $len)
    return $payload
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "ASSEMBLE_FAIL: manifest not found: $ManifestPath"
}

$repoRoot = Resolve-SkillRepoRoot
. (Join-Path $repoRoot "scripts\wrap-prompt-envelope.ps1")
. (Join-Path $repoRoot "scripts\security\redact-secrets.ps1")

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$manifestOrder = @($manifest.PSObject.Properties.Name)

$orderedEntitlements = New-Object System.Collections.Generic.List[string]
foreach ($first in @("contracts", "glossary")) {
    if ($RequiredEntitlements -contains $first) {
        $orderedEntitlements.Add($first)
    }
}
foreach ($name in $manifestOrder) {
    if (($RequiredEntitlements -contains $name) -and -not ($orderedEntitlements -contains $name)) {
        $orderedEntitlements.Add($name)
    }
}
foreach ($name in $RequiredEntitlements) {
    if (-not ($orderedEntitlements -contains $name)) {
        $orderedEntitlements.Add($name)
    }
}

$missing = @()
foreach ($name in $orderedEntitlements) {
    if (-not ($manifest.PSObject.Properties.Name -contains $name)) {
        $missing += $name
    }
}
if ($missing.Count -gt 0) {
    throw ("ASSEMBLE_FAIL: missing entitlement(s) in manifest: " + ($missing -join ", "))
}

$bundleStream = New-Object System.IO.MemoryStream
$lf = [byte[]](0x0A)
$entryRows = @()
for ($i = 0; $i -lt $orderedEntitlements.Count; $i++) {
    $name = $orderedEntitlements[$i]
    $entry = $manifest.$name
    $path = [string]$entry.path
    if (-not (Test-Path -LiteralPath $path)) {
        throw "ASSEMBLE_FAIL: entitlement '$name' path missing: $path"
    }

    $payload = Get-ReferencePackPayloadBytes -Path $path
    $actualPayloadHash = Get-Sha256HexFromBytes -Bytes $payload
    $expectedPayloadHash = [string]$entry.payload_sha256
    if (-not [string]::IsNullOrWhiteSpace($expectedPayloadHash) -and $actualPayloadHash -ne $expectedPayloadHash.ToLowerInvariant()) {
        throw ("ASSEMBLE_FAIL: entitlement '{0}' payload hash mismatch expected={1} actual={2}" -f $name, $expectedPayloadHash, $actualPayloadHash)
    }

    if ($i -gt 0) {
        [void]$bundleStream.Write($lf, 0, 1)
    }
    [void]$bundleStream.Write($payload, 0, $payload.Length)

    $entryRows += [pscustomobject]@{
        name = $name
        path = (Resolve-Path -LiteralPath $path).Path
        payload_sha256 = $actualPayloadHash
    }
}
$bundleBytes = $bundleStream.ToArray()
$bundleSha = Get-Sha256HexFromBytes -Bytes $bundleBytes
$bundleText = [System.Text.Encoding]::UTF8.GetString($bundleBytes)

if ([string]::IsNullOrWhiteSpace($PreamblePath) -and [string]::IsNullOrWhiteSpace($PreambleText)) {
    throw "ASSEMBLE_FAIL: provide either -PreamblePath or -PreambleText"
}
if ([string]::IsNullOrWhiteSpace($BriefPath) -and [string]::IsNullOrWhiteSpace($BriefText)) {
    throw "ASSEMBLE_FAIL: provide either -BriefPath or -BriefText"
}

$preambleSource = if (-not [string]::IsNullOrWhiteSpace($PreamblePath)) {
    Get-Content -LiteralPath $PreamblePath -Raw
}
else {
    $PreambleText
}
$briefSource = if (-not [string]::IsNullOrWhiteSpace($BriefPath)) {
    Get-Content -LiteralPath $BriefPath -Raw
}
else {
    $BriefText
}

$preamble = Invoke-SecretRedaction -Text $preambleSource
$brief = Invoke-SecretRedaction -Text $briefSource
$envelope = New-PromptEnvelope -Label "REFERENCE DATA" -Content $bundleText

$headerLines = @(
    "RUN_ID: $RunId"
    "chunk_id: $ChunkId"
    "attempt: $Attempt"
    "bundle_sha256: $bundleSha"
    "bundle_bytes: $($bundleBytes.Length)"
    "reference_pack_order: $($orderedEntitlements -join ',')"
)
foreach ($row in $entryRows) {
    $headerLines += ("reference_pack.{0}.payload_sha256: {1}" -f $row.name, $row.payload_sha256)
}

$assembled = @(
    ($headerLines -join "`n")
    ""
    $preamble
    ""
    $envelope
    ""
    $brief
    ""
    @"
Return exactly one structured report with these fields and echo values exactly:
DT_BUILD_REPORT_VERSION: 1
RUN_ID: $RunId
chunk_id: $ChunkId
attempt: $Attempt
CHANGED_FILES:
<one path per line, or NONE>
COMMANDS_AND_RESULTS:
<exact command and result per line, or NONE>
UNRESOLVED_BLOCKERS:
<one blocker per line, or NONE>
"@
) -join "`n"

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
[System.IO.File]::WriteAllBytes($OutputPath, [System.Text.UTF8Encoding]::new($false).GetBytes($assembled))

$result = [pscustomobject]@{
    prompt_path = (Resolve-Path -LiteralPath $OutputPath).Path
    run_id = $RunId
    chunk_id = $ChunkId
    attempt = $Attempt
    bundle_sha256 = $bundleSha
    bundle_bytes = $bundleBytes.Length
    entitlements = $orderedEntitlements
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else {
    Write-Output $result.prompt_path
}
