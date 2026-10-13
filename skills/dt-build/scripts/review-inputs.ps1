# Dot-source only. These helpers do not alter live inputs or run-authored authority records.
. (Join-Path $PSScriptRoot 'path-identity.ps1')

# The entire mutable set lives here. Roles must be explicitly declared at prep; every other
# input is immutable. An authority/approval/source/predecessor role always takes precedence
# over a filename: never classify an authorization record as an operator guide.
$script:DtReviewMutableKinds = @{
    'operator-notes' = @{ format = 'operator-json'; extensions = @('.json'); basename = 'operator-notes.json' }
    'operator-guide' = @{ format = 'guide'; extensions = @('.md', '.txt') }
    'ops-guide' = @{ format = 'guide'; extensions = @('.md', '.txt') }
    'append-only-notes' = @{ format = 'lines'; extensions = @('.jsonl', '.md', '.txt', '.log') }
}

function Get-DtReviewInputFormat {
    param([string]$Kind, [string]$Path)
    if (-not $script:DtReviewMutableKinds.ContainsKey($Kind)) {
        if ($Kind -notin @('immutable', 'source', 'authority', 'approvals', 'predecessor-evidence')) { throw "REVIEW_INPUT_KIND: $Kind" }
        return 'immutable'
    }
    $rule = $script:DtReviewMutableKinds[$Kind]
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -notin $rule.extensions -or
        ($rule.ContainsKey('basename') -and [IO.Path]::GetFileName($Path) -ine $rule.basename)) {
        throw "REVIEW_INPUT_KIND_PATH: $Kind cannot describe $Path"
    }
    return $rule.format
}

function Get-DtReviewBytes {
    param([string]$Path)
    # One byte image supplies both the snapshot and its digest. Atomic note replacement is safe.
    $stream = [IO.File]::Open($Path, 'Open', 'Read', [IO.FileShare]::Read -bor [IO.FileShare]::Delete)
    $memory = [IO.MemoryStream]::new()
    try { $stream.CopyTo($memory); return ,$memory.ToArray() }
    finally { $memory.Dispose(); $stream.Dispose() }
}

function Get-DtReviewDigest {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-DtReviewFilePin {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, 'Open', 'Read', [IO.FileShare]::Read -bor [IO.FileShare]::Delete)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return @{ bytes = $stream.Length; sha256 = [Convert]::ToHexString($hasher.ComputeHash($stream)).ToLowerInvariant() }
    } finally { $hasher.Dispose(); $stream.Dispose() }
}

function Get-DtReviewEntries {
    param([byte[]]$Bytes, [string]$Format)
    $text = [Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xfeff)
    if ($Format -eq 'operator-json') {
        $value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100
        if (-not ($value -is [System.Collections.IDictionary]) -or -not $value.Contains('notes') -or $value.notes -isnot [array]) { throw 'REVIEW_NOTES_FORMAT: expected notes array' }
        return @($value.notes | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress -Depth 100 })
    }
    return @($text -split '\r?\n' | Where-Object { $_.Length -gt 0 })
}

function New-DtReviewPacket {
    param([Parameter(Mandatory)][string]$InputManifestPath, [Parameter(Mandatory)][string]$PacketDirectory)
    $manifestPath = ConvertTo-DtPathIdentity $InputManifestPath
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -AsHashtable -Depth 100
    if (-not $manifest.Contains('inputs') -or $manifest.inputs -isnot [array] -or $manifest.inputs.Count -eq 0) { throw 'REVIEW_INPUTS_REQUIRED' }
    $directory = ConvertTo-DtPathIdentity $PacketDirectory
    if (Test-Path -LiteralPath $directory) { throw "REVIEW_PACKET_EXISTS: $directory" }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $prepared = @($manifest.inputs | ForEach-Object {
        $path = [string]$_.path
        if (-not [IO.Path]::IsPathFullyQualified($path)) { $path = Join-Path ([IO.Path]::GetDirectoryName($manifestPath)) $path }
        $path = ConvertTo-DtPathIdentity $path
        if (-not $seen.Add($path)) { throw "REVIEW_INPUT_DUPLICATE: $path" }
        $kind = if ($_.Contains('kind')) { [string]$_.kind } else { 'immutable' }
        $format = Get-DtReviewInputFormat $kind $path
        $bytes = $null
        if ($format -eq 'immutable') { $pin = Get-DtReviewFilePin $path }
        else {
            $bytes = Get-DtReviewBytes $path
            if ($format -in @('operator-json', 'lines')) { $null = @(Get-DtReviewEntries $bytes $format) }
            $pin = @{ bytes = $bytes.Length; sha256 = Get-DtReviewDigest $bytes }
        }
        @{ path = $path; kind = $kind; format = $format; data = $bytes; pin = $pin }
    })
    # Validate all inputs before creating anything. Create-new protects an existing packet.
    $null = [IO.Directory]::CreateDirectory($directory)
    $records = @()
    $index = 0
    foreach ($item in $prepared) {
        $reviewPath = $item.path
        if ($item.format -ne 'immutable') {
            $reviewPath = Join-Path $directory ('{0:D4}-{1}' -f $index, [IO.Path]::GetFileName($item.path))
            $out = [IO.File]::Open($reviewPath, 'CreateNew', 'Write', 'None')
            try { $out.Write($item.data, 0, $item.data.Length) } finally { $out.Dispose() }
        }
        $records += [ordered]@{ path = $item.path; kind = $item.kind; review_path = $reviewPath; bytes = $item.pin.bytes; sha256 = $item.pin.sha256 }
        $index++
    }
    $packet = [ordered]@{ schema = 'dt-build-review-inputs/v1'; prepared_utc = [DateTime]::UtcNow.ToString('o'); inputs = $records }
    $packetPath = Join-Path $directory 'review-inputs.json'
    $out = [IO.File]::Open($packetPath, 'CreateNew', 'Write', 'None')
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($packet | ConvertTo-Json -Depth 100))
        $out.Write($bytes, 0, $bytes.Length)
    } finally { $out.Dispose() }
    return [ordered]@{ packet_path = $packetPath; packet_sha256 = Get-DtReviewDigest $bytes; inputs = $records }
}

function Test-DtReviewPacket {
    param([Parameter(Mandatory)][string]$PacketPath, [Parameter(Mandatory)][string]$ExpectedPacketSha256)
    $packetBytes = Get-DtReviewBytes $PacketPath
    if ((Get-DtReviewDigest $packetBytes) -cne $ExpectedPacketSha256) { throw 'REVIEW_PACKET_HASH_DRIFT' }
    $packet = [Text.Encoding]::UTF8.GetString($packetBytes) | ConvertFrom-Json -AsHashtable -Depth 100
    if ($packet.schema -cne 'dt-build-review-inputs/v1' -or $packet.inputs -isnot [array] -or $packet.inputs.Count -eq 0) { throw 'REVIEW_PACKET_SCHEMA' }
    $changes = @()
    foreach ($item in $packet.inputs) {
        $path = ConvertTo-DtPathIdentity $item.path
        $reviewPath = ConvertTo-DtPathIdentity $item.review_path
        $format = Get-DtReviewInputFormat $item.kind $path
        if ($format -eq 'immutable' -and -not (Test-DtPathEqual $path $reviewPath)) { throw 'REVIEW_IMMUTABLE_LIVE_PIN_REQUIRED' }
        if ($format -ne 'immutable' -and (Test-DtPathEqual $path $reviewPath)) { throw 'REVIEW_MUTABLE_SNAPSHOT_REQUIRED' }
        $reviewPin = Get-DtReviewFilePin $reviewPath
        if ($reviewPin.bytes -ne $item.bytes -or $reviewPin.sha256 -cne $item.sha256) { throw "REVIEW_INPUT_HASH_DRIFT: $reviewPath" }
        if ($format -eq 'immutable') { continue }
        $reviewBytes = Get-DtReviewBytes $reviewPath
        if ($reviewBytes.Length -ne $item.bytes -or (Get-DtReviewDigest $reviewBytes) -cne $item.sha256) { throw "REVIEW_INPUT_HASH_DRIFT: $reviewPath" }
        try {
            $liveBytes = Get-DtReviewBytes $path
            if ((Get-DtReviewDigest $liveBytes) -ceq $item.sha256) { continue }
            $info = [ordered]@{ path = $path; kind = $item.kind; message = 'guide changed since review prep'; new_entries = $null; removed_entries = $null }
            if ($format -in @('operator-json', 'lines')) {
                $old = @(Get-DtReviewEntries $reviewBytes $format)
                $live = @(Get-DtReviewEntries $liveBytes $format)
                # Multiset comparison also detects removals/edits and duplicate appended lines.
                $remaining = [Collections.Generic.List[string]]::new()
                foreach ($entry in $old) { $remaining.Add($entry) }
                $added = 0
                foreach ($entry in $live) { if (-not $remaining.Remove($entry)) { $added++ } }
                $info.new_entries = $added; $info.removed_entries = $remaining.Count
                $info.message = "notes changed since review prep: $added new entries; $($remaining.Count) removed or edited entries"
            }
            $changes += $info
        } catch {
            $changes += [ordered]@{ path = $path; kind = $item.kind; message = 'mutable input unavailable or unreadable since review prep'; new_entries = $null; removed_entries = $null }
        }
    }
    return [ordered]@{ pass = $true; checked_inputs = $packet.inputs.Count; changes = @($changes) }
}
