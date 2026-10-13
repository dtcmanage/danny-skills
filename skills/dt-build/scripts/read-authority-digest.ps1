#Requires -Version 7.0
param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$BuildStatePath)
# Verified full read through a script: digest reads are not evidence slices and must not be
# blocked by a prior context-wall or repeat-read entry. Hard context limits still require handoff.
$verification = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath | ConvertFrom-Json
$manifestPath = Join-Path $RunFolder 'authority-digest.json'
$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
$manifestHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant()
if ($manifestHash -cne $verification.manifest_sha256) { throw 'AUTHORITY_MANIFEST_HASH: manifest changed during read' }
$manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
$bytes = [IO.File]::ReadAllBytes((Join-Path $RunFolder 'authority-digest.md'))
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
if ($hash -cne $manifest.markdown_sha256) { throw 'AUTHORITY_DIGEST_HASH: digest changed during read' }
[Text.Encoding]::UTF8.GetString($bytes)
