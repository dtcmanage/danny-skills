#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$PacketPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPacketSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'review-inputs.ps1')
Test-DtReviewPacket -PacketPath $PacketPath -ExpectedPacketSha256 $ExpectedPacketSha256 | ConvertTo-Json -Depth 100
