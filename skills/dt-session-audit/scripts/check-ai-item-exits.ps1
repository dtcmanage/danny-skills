param(
    [string]$TranscriptPath,
    [string]$SessionStartUtc,
    [string]$BaseUrl = 'http://192.168.68.17:8080',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-TranscriptNotFound([string]$Detail) {
    [Console]::Error.WriteLine("TRANSCRIPT_NOT_FOUND: $Detail Run from the session's own working directory or pass -TranscriptPath.")
    exit 2
}

if ($TranscriptPath) {
    if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) { Stop-TranscriptNotFound "no transcript at $TranscriptPath." }
} else {
    $configDir = $env:CLAUDE_CONFIG_DIR
    if (-not $configDir) { $configDir = Join-Path $HOME '.claude' }
    $projectsDir = Join-Path $configDir 'projects'
    $projectName = (Get-Location).Path -replace '[^a-zA-Z0-9]', '-'
    $projectDir = Join-Path $projectsDir $projectName
    # Many sessions share one project folder, so the session id is the only safe key.
    $sessionId = @($env:CLAUDE_SESSION_ID, $env:CLAUDE_CODE_SESSION_ID) | Where-Object { $_ } | Select-Object -First 1
    if ($sessionId) {
        if ($sessionId -notmatch '^[A-Za-z0-9-]+$') { Stop-TranscriptNotFound "session id '$sessionId' is not a transcript name." }
        $byId = Join-Path $projectDir "$sessionId.jsonl"
        if (-not (Test-Path -LiteralPath $byId -PathType Leaf)) {
            # The session may have started in another directory; ids are unique across project folders.
            $byId = Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName "$sessionId.jsonl" } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        }
        if (-not $byId) { Stop-TranscriptNotFound "no transcript for session $sessionId under $projectsDir." }
        $TranscriptPath = $byId
    } else {
        # Main transcripts are direct children; never select files in nested folders.
        $newest = Get-ChildItem -LiteralPath $projectDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($null -eq $newest) { Stop-TranscriptNotFound "no session id in the environment and no transcript in $projectDir." }
        $TranscriptPath = $newest.FullName
        [Console]::Error.WriteLine("WARNING: no session id in the environment; using the newest transcript in the project folder, which may belong to another session: $TranscriptPath")
    }
}

function Get-Field($Object, [string]$Name) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $null
}

function Get-Strings($Value) {
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        # Codex function-call arguments are themselves JSON strings.
        if ($Value.TrimStart().StartsWith('{')) {
            try { $decoded = ConvertFrom-Json -InputObject $Value -ErrorAction Stop }
            catch { $decoded = $null }
            if ($null -ne $decoded) { Get-Strings $decoded; return }
        }
        $Value
    } elseif ($Value -is [System.Collections.IEnumerable]) {
        foreach ($entry in $Value) { Get-Strings $entry }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) { Get-Strings $property.Value }
    }
}

function Convert-Timestamp([string]$Value) {
    return [datetimeoffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
}

$touched = [Collections.Generic.HashSet[int]]::new()
$firstTimestamp = $null
$starterSeen = $false
foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $TranscriptPath).Path)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $record = $line | ConvertFrom-Json
    if ($null -eq $firstTimestamp) {
        $stamp = Get-Field $record 'timestamp'
        if ($stamp) { $firstTimestamp = Convert-Timestamp $stamp }
    }
    $text = @(Get-Strings $record) -join "`n"
    foreach ($match in [regex]::Matches($text, '(?m)^Command Center item #(\d+)\b')) {
        [void]$touched.Add([int]$match.Groups[1].Value)
    }
    # Explicit numbered commands, including quoted absolute cc.ps1 paths.
    foreach ($match in [regex]::Matches($text, '(?i)\bcc\.ps1["''`]?\s+(?:update|done|attempt|keep)\s+(\d+)\b')) {
        [void]$touched.Add([int]$match.Groups[1].Value)
    }
    # CLI write echoes identify adds too; arbitrary prose mentioning #N is not an echo.
    foreach ($match in [regex]::Matches($text, '(?m)^\s*#(\d+)\s+\S[^\r\n]*$')) {
        [void]$touched.Add([int]$match.Groups[1].Value)
    }
    $message = Get-Field $record 'message'
    $payload = Get-Field $record 'payload'
    $userContent = $null
    if ((Get-Field $message 'role') -eq 'user') { $userContent = Get-Field $message 'content' }
    elseif ((Get-Field $record 'role') -eq 'user') { $userContent = Get-Field $record 'content' }
    elseif ((Get-Field $payload 'role') -eq 'user') { $userContent = Get-Field $payload 'content' }
    elseif ((Get-Field $payload 'type') -eq 'user_message') { $userContent = Get-Field $payload 'message' }
    # Tool-result blocks in Claude's user envelope are not a starter prompt.
    $promptParts = @($userContent | Where-Object { $_ -is [string] -or (Get-Field $_ 'type') -in @('text', 'input_text') })
    if (-not $starterSeen -and $promptParts.Count -gt 0) {
        $starterSeen = $true
        foreach ($match in [regex]::Matches((@(Get-Strings $promptParts) -join "`n"), '#(\d+)\b')) {
            [void]$touched.Add([int]$match.Groups[1].Value)
        }
    }
}
if ($SessionStartUtc) { $start = Convert-Timestamp $SessionStartUtc }
elseif ($null -ne $firstTimestamp) { $start = $firstTimestamp }
else { throw 'Transcript has no timestamp; supply -SessionStartUtc.' }

$findings = @()
$couldNotCheck = $false
if ($touched.Count -gt 0) {
    try {
        # Read-only LAN endpoint: no key or workstation filter is needed.
        $ready = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + '/items/ready') -TimeoutSec 5 -Method Get
        foreach ($item in $ready) {
            if ((Get-Field $item 'lane') -ne 'ai' -or -not $touched.Contains([int]$item.num)) { continue }
            if ((Convert-Timestamp $item.updated_at) -ge $start) { continue }
            $num = [int]$item.num
            $findings += [pscustomobject]@{
                num = $num
                title = [string]$item.title
                allowed_exits = @(
                    "done $num --done-note <what finished>",
                    "update $num --run-on/--after-item <trigger> with a note in --context",
                    "update $num --lane you-then-ai|yours with the question in --next-action"
                )
            }
        }
    } catch { $couldNotCheck = $true; $findings = @() }
}
$result = [pscustomobject]@{
    session_start_utc = $start.ToString('o')
    touched_items = @($touched | Sort-Object)
    findings = @($findings | Sort-Object num)
    could_not_check = $couldNotCheck
}
if ($Json) { $result | ConvertTo-Json -Depth 5 }
elseif ($couldNotCheck) { 'Command Center: could not check AI-item exits (server unavailable or invalid response).' }
else {
    foreach ($finding in $result.findings) {
        "#$($finding.num) $($finding.title) - allowed exits: $($finding.allowed_exits -join '; ')."
    }
}
