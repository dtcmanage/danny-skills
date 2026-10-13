#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$InputManifestPath,
    [Parameter(Mandatory)][string]$PacketDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'review-inputs.ps1')
New-DtReviewPacket -InputManifestPath $InputManifestPath -PacketDirectory $PacketDirectory | ConvertTo-Json -Depth 100
