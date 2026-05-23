param(
    [Parameter(Mandatory)]
    [string]$RunDirectory,

    [Parameter(Mandatory)]
    [string]$ContractsSourcePath,

    [Parameter(Mandatory)]
    [string]$GlossarySourcePath,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Convert-ToPayloadBlock {
    param([Parameter(Mandatory)][string]$Text)
    $lines = $Text -split "`r?`n"
    if ($lines.Count -eq 0) { return "| " }
    return (($lines | ForEach-Object { "| $_" }) -join "`n")
}

function Write-ReferencePackFile {
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PayloadText
    )

    $payloadBlock = Convert-ToPayloadBlock -Text $PayloadText
    $raw = @(
        "RUN_ID: $RunId"
        "=== REFERENCE PACK PAYLOAD ==="
        $payloadBlock
    ) -join "`n"

    [System.IO.File]::WriteAllText($OutputPath, $raw, [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        path = (Resolve-Path -LiteralPath $OutputPath).Path
        file_sha256 = Get-FileSha256 -Path $OutputPath
        payload_sha256 = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payloadBlock))
        ).Replace("-", "").ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $OutputPath).Length
    }
}

if (-not (Test-Path -LiteralPath $ContractsSourcePath)) {
    throw "Contracts source not found: $ContractsSourcePath"
}
if (-not (Test-Path -LiteralPath $GlossarySourcePath)) {
    throw "Glossary source not found: $GlossarySourcePath"
}

New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
$runId = Split-Path -Leaf $RunDirectory

$contractsOut = Join-Path $RunDirectory "reference-pack-contracts.md"
$glossaryOut = Join-Path $RunDirectory "reference-pack-glossary.md"

$contractsPayload = Get-Content -LiteralPath $ContractsSourcePath -Raw
$glossaryPayload = Get-Content -LiteralPath $GlossarySourcePath -Raw

$contractsEntry = Write-ReferencePackFile -OutputPath $contractsOut -RunId $runId -PayloadText $contractsPayload
$glossaryEntry = Write-ReferencePackFile -OutputPath $glossaryOut -RunId $runId -PayloadText $glossaryPayload

$manifest = [ordered]@{
    contracts = $contractsEntry
    glossary = $glossaryEntry
}

$manifestPath = Join-Path $RunDirectory "reference-manifest.md"
$manifestRaw = ($manifest | ConvertTo-Json -Depth 5)
[System.IO.File]::WriteAllText($manifestPath, $manifestRaw, [System.Text.UTF8Encoding]::new($false))

$result = [pscustomobject]@{
    manifest_path = (Resolve-Path -LiteralPath $manifestPath).Path
    entries = $manifest
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else {
    Write-Output $result.manifest_path
}
