param(
    [Parameter(Mandatory)]
    [string]$PromptPath,

    [string]$ExpectedRunId = "",
    [string]$ExpectedChunkId = "",
    [ValidateRange(1, 2)][Nullable[int]]$ExpectedAttempt = $null,

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

if (-not (Test-Path -LiteralPath $PromptPath)) {
    throw "VERIFY_PROMPT_FAIL: prompt file not found: $PromptPath"
}

$repoRoot = Resolve-SkillRepoRoot
. (Join-Path $repoRoot "scripts\security\redact-secrets.ps1")

$bytes = [System.IO.File]::ReadAllBytes($PromptPath)
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
$errors = New-Object System.Collections.Generic.List[string]

# Check 1: identity.
$runIdMatch = [regex]::Match($text, '(?m)^RUN_ID:\s*(.+?)\s*$')
$chunkMatch = [regex]::Match($text, '(?m)^chunk_id:\s*(.+?)\s*$')
$attemptMatch = [regex]::Match($text, '(?m)^attempt:\s*(\d+)\s*$')
$bundleMatch = [regex]::Match($text, '(?m)^bundle_sha256:\s*([a-fA-F0-9]{64})\s*$')

if (-not $runIdMatch.Success) { $errors.Add("identity: RUN_ID missing") }
if (-not $chunkMatch.Success) { $errors.Add("identity: chunk_id missing") }
if (-not $attemptMatch.Success) { $errors.Add("identity: attempt missing or invalid") }
if (-not $bundleMatch.Success) { $errors.Add("identity: bundle_sha256 missing or invalid") }

$runId = if ($runIdMatch.Success) { $runIdMatch.Groups[1].Value.Trim() } else { "" }
$chunkId = if ($chunkMatch.Success) { $chunkMatch.Groups[1].Value.Trim() } else { "" }
$attempt = if ($attemptMatch.Success) { [int]$attemptMatch.Groups[1].Value } else { -1 }
$expectedBundleSha = if ($bundleMatch.Success) { $bundleMatch.Groups[1].Value.ToLowerInvariant() } else { "" }

if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and $runId -ne $ExpectedRunId) {
    $errors.Add(("identity: RUN_ID mismatch expected={0} actual={1}" -f $ExpectedRunId, $runId))
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedChunkId) -and $chunkId -ne $ExpectedChunkId) {
    $errors.Add(("identity: chunk_id mismatch expected={0} actual={1}" -f $ExpectedChunkId, $chunkId))
}
if ($null -ne $ExpectedAttempt -and $attempt -ne [int]$ExpectedAttempt) {
    $errors.Add(("identity: attempt mismatch expected={0} actual={1}" -f [int]$ExpectedAttempt, $attempt))
}
if ($attemptMatch.Success -and $attempt -notin @(1, 2)) {
    $errors.Add(("identity: attempt outside allowed automatic budget (1..2): {0}" -f $attempt))
}

# Check 2: allowed character scan.
for ($i = 0; $i -lt $bytes.Length; $i++) {
    $b = $bytes[$i]
    if (($b -lt 0x20 -and $b -ne 0x09 -and $b -ne 0x0A -and $b -ne 0x0D) -or $b -eq 0x7F) {
        $errors.Add(("allowed-character-scan: disallowed control byte 0x{0} at offset {1}" -f $b.ToString("X2"), $i))
        break
    }
}

# Check 3: delimiter balance.
$beginMarker = "=== BEGIN REFERENCE DATA ==="
$endMarker = "=== END REFERENCE DATA ==="
$beginMatches = [regex]::Matches($text, [regex]::Escape($beginMarker))
$endMatches = [regex]::Matches($text, [regex]::Escape($endMarker))
if ($beginMatches.Count -ne 1) {
    $errors.Add(("delimiter-balance: expected 1 BEGIN marker, found {0}" -f $beginMatches.Count))
}
if ($endMatches.Count -ne 1) {
    $errors.Add(("delimiter-balance: expected 1 END marker, found {0}" -f $endMatches.Count))
}
if ($beginMatches.Count -eq 1 -and $endMatches.Count -eq 1 -and $beginMatches[0].Index -ge $endMatches[0].Index) {
    $errors.Add("delimiter-balance: BEGIN marker must appear before END marker")
}

# Check 4: content equality against recorded bundle hash.
$bundleHashActual = ""
if ($beginMatches.Count -eq 1 -and $endMatches.Count -eq 1) {
    $beginBytes = [System.Text.Encoding]::UTF8.GetBytes($beginMarker)
    $endBytes = [System.Text.Encoding]::UTF8.GetBytes($endMarker)
    $beginIndex = Find-ByteSequence -Buffer $bytes -Needle $beginBytes
    $endIndex = Find-ByteSequence -Buffer $bytes -Needle $endBytes

    if ($beginIndex -lt 0 -or $endIndex -lt 0 -or $beginIndex -ge $endIndex) {
        $errors.Add("content-equality: unable to locate delimiter byte offsets")
    }
    else {
        $afterBegin = $beginIndex + $beginBytes.Length
        if ($afterBegin -ge $bytes.Length) {
            $errors.Add("content-equality: BEGIN marker has no payload section")
        }
        else {
            $dataStart = $afterBegin
            if ($bytes[$dataStart] -eq 0x0D) { $dataStart++ }
            if ($dataStart -lt $bytes.Length -and $bytes[$dataStart] -eq 0x0A) { $dataStart++ }

            $dataEnd = $endIndex
            if ($dataEnd -gt $dataStart -and $bytes[$dataEnd - 1] -eq 0x0A) { $dataEnd-- }
            if ($dataEnd -gt $dataStart -and $bytes[$dataEnd - 1] -eq 0x0D) { $dataEnd-- }

            if ($dataEnd -lt $dataStart) {
                $errors.Add("content-equality: invalid payload bounds")
            }
            else {
                $length = $dataEnd - $dataStart
                $payloadBytes = if ($length -gt 0) {
                    $arr = New-Object byte[] $length
                    [System.Array]::Copy($bytes, $dataStart, $arr, 0, $length)
                    $arr
                }
                else {
                    [byte[]]@()
                }

                $bundleHashActual = Get-Sha256HexFromBytes -Bytes $payloadBytes
                if (-not [string]::IsNullOrWhiteSpace($expectedBundleSha) -and $bundleHashActual -ne $expectedBundleSha) {
                    $errors.Add(("content-equality: bundle hash mismatch expected={0} actual={1}" -f $expectedBundleSha, $bundleHashActual))
                }
            }
        }
    }
}

$result = [pscustomobject]@{
    pass = ($errors.Count -eq 0)
    run_id = $runId
    chunk_id = $chunkId
    attempt = if ($attempt -ge 0) { $attempt } else { $null }
    expected_bundle_sha256 = $expectedBundleSha
    actual_bundle_sha256 = $bundleHashActual
    prompt_path = (Resolve-Path -LiteralPath $PromptPath).Path
    errors = @($errors)
}

if (-not $result.pass) {
    $joined = (($result.errors | ForEach-Object { Invoke-SecretRedaction -Text $_ }) -join "`n- ")
    if ($Json) {
        $result | ConvertTo-Json -Depth 6
        exit 1
    }
    throw ("VERIFY_PROMPT_FAIL:`n- " + $joined)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else {
    Write-Output ("PASS: codex prompt verify gate passed for {0}" -f $result.prompt_path)
}
