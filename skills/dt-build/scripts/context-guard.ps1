#Requires -Version 7.0
# Reads a coordinator's latest context size from its own transcript, reading from the end so a
# multi-MB transcript is never loaded whole. Claude: the last assistant usage (input_tokens +
# cache_read_input_tokens + cache_creation_input_tokens) of the latest request. Codex: the last
# token_count event's info.last_token_usage.input_tokens. Same fields collect-usage.py reads.
# dt-job.ps1, the watcher, and the Claude hooks dot-source this file for the parsing, transcript
# discovery, and limits, so there is one implementation of each.
param(
    # $Host is an automatic variable, and dot-sourcing callers have their own -Json and -TranscriptPath,
    # so these bind through aliases to names no caller uses.
    [Alias('Host')]
    [ValidateSet('claude', 'codex')]
    [string]$GuardHost,

    [Alias('TranscriptPath')]
    [string]$GuardTranscriptPath,

    [Alias('Json')]
    [switch]$GuardJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DtCtxBlockBytes = 65536
$script:DtCtxDefaultSoftMargin = 40000
$script:DtCtxDefaultHardMargin = 70000
$script:DtCtxDefaultCeiling = 200000
$script:DtCtxDiscoveryCandidates = 20
$script:DtCtxDiscoveryHeadLines = 15

function Get-DtCtxLimitSetting {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$Default)
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    $parsed = [long]0
    if ($value -and [long]::TryParse($value, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $Default
}

function ConvertFrom-DtCtxLine {
    # The tokens one transcript line carries, or $null when it carries none.
    param([Parameter(Mandatory)][string]$TranscriptHost, [Parameter(Mandatory)][string]$Line)
    if ($TranscriptHost -eq 'claude') {
        # Cheap prefilter before parsing: only assistant lines with usage count.
        if (-not $Line.Contains('"usage"') -or $Line -notmatch '"type"\s*:\s*"assistant"') { return $null }
        try { $row = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
        if ($null -eq $row -or -not $row.PSObject.Properties['type'] -or $row.type -ne 'assistant') { return $null }
        if ($row.PSObject.Properties['isSidechain'] -and $row.isSidechain) { return $null }
        if (-not $row.PSObject.Properties['message'] -or $null -eq $row.message -or -not $row.message.PSObject.Properties['usage']) { return $null }
        $usage = $row.message.usage
        if ($null -eq $usage) { return $null }
        $sum = [long]0
        foreach ($field in @('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')) {
            if ($usage.PSObject.Properties[$field] -and $null -ne $usage.$field) { $sum += [long]$usage.$field }
        }
        # Synthetic and empty messages carry all-zero usage; the latest real request is wanted.
        if ($sum -le 0) { return $null }
        return $sum
    }
    if (-not $Line.Contains('"token_count"')) { return $null }
    try { $row = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $row -or -not $row.PSObject.Properties['payload'] -or $null -eq $row.payload) { return $null }
    $payload = $row.payload
    if (-not $payload.PSObject.Properties['type'] -or $payload.type -ne 'token_count') { return $null }
    if (-not $payload.PSObject.Properties['info'] -or $null -eq $payload.info) { return $null }
    $info = $payload.info
    if (-not $info.PSObject.Properties['last_token_usage'] -or $null -eq $info.last_token_usage) { return $null }
    $last = $info.last_token_usage
    if (-not $last.PSObject.Properties['input_tokens'] -or $null -eq $last.input_tokens) { return $null }
    return [long]$last.input_tokens
}

function Get-DtCtxTokens {
    # Scans the transcript backwards block by block and stops at the newest line that carries tokens.
    # Claude writes one line per content block of a request, all with that request's usage, so the
    # newest such line is the latest deduped request.
    param([Parameter(Mandatory)][string]$TranscriptHost, [Parameter(Mandatory)][string]$TranscriptPath)
    if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) { throw "CONTEXT_GUARD_NO_TRANSCRIPT: $TranscriptPath" }
    $stream = [System.IO.File]::Open($TranscriptPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $position = $stream.Length
        # Bytes of a line whose start lies in a block not read yet.
        $carry = [byte[]]::new(0)
        while ($position -gt 0) {
            $size = [int][Math]::Min([long]$script:DtCtxBlockBytes, $position)
            $position -= $size
            [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
            $block = [byte[]]::new($size + $carry.Length)
            $read = 0
            while ($read -lt $size) {
                $n = $stream.Read($block, $read, $size - $read)
                if ($n -le 0) { throw "CONTEXT_GUARD_READ_FAILED: $TranscriptPath" }
                $read += $n
            }
            [System.Array]::Copy($carry, 0, $block, $size, $carry.Length)
            $end = $block.Length
            for ($i = $block.Length - 1; $i -ge 0; $i--) {
                if ($block[$i] -ne 10) { continue }
                if ($end - $i - 1 -gt 0) {
                    $tokens = ConvertFrom-DtCtxLine -TranscriptHost $TranscriptHost -Line ([System.Text.Encoding]::UTF8.GetString($block, $i + 1, $end - $i - 1))
                    if ($null -ne $tokens) { return [long]$tokens }
                }
                $end = $i
            }
            $carry = [byte[]]::new($end)
            [System.Array]::Copy($block, 0, $carry, 0, $end)
        }
        if ($carry.Length -gt 0) {
            $tokens = ConvertFrom-DtCtxLine -TranscriptHost $TranscriptHost -Line ([System.Text.Encoding]::UTF8.GetString($carry))
            if ($null -ne $tokens) { return [long]$tokens }
        }
        return $null
    }
    finally { $stream.Dispose() }
}

function Read-DtCtxHeadLines {
    param([Parameter(Mandatory)][string]$Path, [int]$MaxLines = $script:DtCtxDiscoveryHeadLines)
    $lines = [System.Collections.Generic.List[string]]::new()
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        while ($lines.Count -lt $MaxLines) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $lines.Add($line)
        }
    }
    finally { $stream.Dispose() }
    return @($lines)
}

function Test-DtCtxSamePath {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    try { return ([System.IO.Path]::GetFullPath($Left).TrimEnd('\', '/') -ieq [System.IO.Path]::GetFullPath($Right).TrimEnd('\', '/')) }
    catch { return $false }
}

function Test-DtCtxTailContains {
    # True when the last block of the file contains $Text: a session that just ran mark-bootstrap has the
    # call among its newest lines.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $size = [int][Math]::Min([long]$script:DtCtxBlockBytes, $stream.Length)
        [void]$stream.Seek(-$size, [System.IO.SeekOrigin]::End)
        $buffer = [byte[]]::new($size)
        $read = 0
        while ($read -lt $size) {
            $n = $stream.Read($buffer, $read, $size - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read).Contains($Text)
    }
    finally { $stream.Dispose() }
}

function Test-DtCtxCodexChunkPrompt {
    # A dt-build chunk wrapper's prompt opens with RUN_ID and chunk_id header lines (invoke-codex-chunk.ps1
    # refuses a prompt without them); in its rollout that prompt is the first user message, a few lines in.
    param($Row)
    if ($null -eq $Row -or -not $Row.PSObject.Properties['type'] -or $Row.type -ne 'response_item') { return $false }
    if (-not $Row.PSObject.Properties['payload'] -or $null -eq $Row.payload) { return $false }
    $payload = $Row.payload
    if (-not $payload.PSObject.Properties['role'] -or $payload.role -ne 'user' -or -not $payload.PSObject.Properties['content']) { return $false }
    $text = (@($payload.content) | Where-Object { $null -ne $_ -and $_.PSObject.Properties['text'] } | ForEach-Object { [string]$_.text }) -join "`n"
    return ($text -match '(?m)^RUN_ID:[ \t]*\S' -and $text -match '(?m)^chunk_id:[ \t]*\S')
}

function Test-DtCtxCandidate {
    # Whether one transcript can be this cwd's coordinator session. Claude: started in $Cwd and not a
    # subagent (no subagents folder in its path, no isSidechain lines). Codex: session_meta cwd matches,
    # not a subagent thread, and not a rollout a dt-build chunk wrapper started.
    param([Parameter(Mandatory)][string]$TranscriptHost, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Cwd)
    if ($TranscriptHost -eq 'claude') {
        if ($Path -match '[\\/]subagents[\\/]') { return $false }
        foreach ($line in (Read-DtCtxHeadLines -Path $Path)) {
            if (-not $line.Contains('"cwd"')) { continue }
            try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($null -eq $row -or -not $row.PSObject.Properties['cwd']) { continue }
            if ($row.PSObject.Properties['isSidechain'] -and $row.isSidechain) { return $false }
            return (Test-DtCtxSamePath ([string]$row.cwd) $Cwd)
        }
        return $false
    }
    $metaMatched = $false
    foreach ($line in (Read-DtCtxHeadLines -Path $Path)) {
        if (-not $metaMatched) {
            if (-not $line.Contains('session_meta')) { continue }
            try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($null -eq $row -or -not $row.PSObject.Properties['type'] -or $row.type -ne 'session_meta' -or -not $row.PSObject.Properties['payload'] -or $null -eq $row.payload) { continue }
            $meta = $row.payload
            if (-not $meta.PSObject.Properties['cwd'] -or -not (Test-DtCtxSamePath ([string]$meta.cwd) $Cwd)) { return $false }
            if ($meta.PSObject.Properties['thread_source'] -and $meta.thread_source -eq 'subagent') { return $false }
            $metaMatched = $true
            continue
        }
        if (-not $line.Contains('RUN_ID:') -or -not $line.Contains('chunk_id:')) { continue }
        try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (Test-DtCtxCodexChunkPrompt $row) { return $false }
    }
    return $metaMatched
}

function Find-DtCtxTranscript {
    # The transcript of the coordinator session started in $Cwd, used only when the caller names none.
    # Claude: *.jsonl under $CLAUDE_CONFIG_DIR\projects (default ~\.claude\projects). Codex: a rollout under
    # $CODEX_HOME\sessions (default ~\.codex\sessions). Among the candidates Test-DtCtxCandidate accepts,
    # the newest one whose latest lines carry a mark-bootstrap call wins, else the newest. A discovered
    # transcript is a guess: its session is never recorded as a coordinator session for the hooks.
    param([Parameter(Mandatory)][string]$TranscriptHost, [string]$Cwd = (Get-Location).ProviderPath)
    if ($TranscriptHost -eq 'claude') {
        $base = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
        $root = Join-Path $base 'projects'
        # Claude names the project folder after the cwd with every non-alphanumeric character a dash.
        $slugDir = Join-Path $root ($Cwd -replace '[^A-Za-z0-9]', '-')
        $searchRoot = if (Test-Path -LiteralPath $slugDir -PathType Container) { $slugDir } else { $root }
    }
    else {
        $base = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
        $searchRoot = Join-Path $base 'sessions'
    }
    if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) { throw "CONTEXT_GUARD_NO_TRANSCRIPT: no $TranscriptHost transcript folder at $searchRoot" }
    $filter = if ($TranscriptHost -eq 'claude') { '*.jsonl' } else { 'rollout-*.jsonl' }
    $candidates = @(Get-ChildItem -LiteralPath $searchRoot -Recurse -File -Filter $filter -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $script:DtCtxDiscoveryCandidates)
    $newest = $null
    foreach ($file in $candidates) {
        if (-not (Test-DtCtxCandidate -TranscriptHost $TranscriptHost -Path $file.FullName -Cwd $Cwd)) { continue }
        if (Test-DtCtxTailContains -Path $file.FullName -Text 'mark-bootstrap') { return $file.FullName }
        if ($null -eq $newest) { $newest = $file.FullName }
    }
    if ($null -ne $newest) { return $newest }
    throw "CONTEXT_GUARD_NO_TRANSCRIPT: no $TranscriptHost transcript under $searchRoot was started in $Cwd"
}

function Get-DtCtxSessionId {
    # Claude names a transcript after its session id; Codex records it in session_meta.
    param([Parameter(Mandatory)][string]$TranscriptHost, [Parameter(Mandatory)][string]$TranscriptPath)
    if ($TranscriptHost -eq 'claude') { return [System.IO.Path]::GetFileNameWithoutExtension($TranscriptPath) }
    foreach ($line in (Read-DtCtxHeadLines -Path $TranscriptPath)) {
        if (-not $line.Contains('session_meta')) { continue }
        try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($row.PSObject.Properties['payload'] -and $null -ne $row.payload -and $row.payload.PSObject.Properties['id']) { return [string]$row.payload.id }
    }
    return $null
}

function Get-DtCtxState {
    # ok / checkpoint / rotate. With a bootstrap baseline: soft = baseline + 40k, hard = baseline + 70k.
    # Before the marker only the 200k ceiling applies, reported as the hard limit.
    param([Nullable[long]]$Tokens, [Nullable[long]]$Baseline)
    $soft = $null
    if ($null -ne $Baseline) {
        $soft = [long]$Baseline + (Get-DtCtxLimitSetting -Name 'DT_BUILD_CTX_SOFT_MARGIN' -Default $script:DtCtxDefaultSoftMargin)
        $hard = [long]$Baseline + (Get-DtCtxLimitSetting -Name 'DT_BUILD_CTX_HARD_MARGIN' -Default $script:DtCtxDefaultHardMargin)
    }
    else { $hard = Get-DtCtxLimitSetting -Name 'DT_BUILD_CTX_CEILING' -Default $script:DtCtxDefaultCeiling }
    $state = 'ok'
    if ($null -ne $Tokens) {
        if ([long]$Tokens -ge $hard) { $state = 'rotate' }
        elseif ($null -ne $soft -and [long]$Tokens -ge $soft) { $state = 'checkpoint' }
    }
    $fmt = { param($v) if ($null -eq $v) { 'none' } else { [string]$v } }
    $line = "context: $(& $fmt $Tokens) $state (baseline $(& $fmt $Baseline), soft $(& $fmt $soft), hard $hard)"
    return [pscustomobject][ordered]@{ tokens = $Tokens; state = $state; baseline = $Baseline; soft = $soft; hard = $hard; line = $line }
}

function Split-DtCtxIrreversibleSteps {
    # Open irreversible steps split by who opened them. Only steps opened by the current lease holder (an
    # unreleased lease) defer rotation; a step whose coordinator no longer holds the lease is stale and
    # defers nothing.
    param([AllowEmptyCollection()][object[]]$Open = @(), $Lease)
    $holder = $null
    if ($null -ne $Lease -and $Lease.PSObject.Properties['coordinator_id'] -and -not ($Lease.PSObject.Properties['released_utc'] -and $Lease.released_utc)) { $holder = [string]$Lease.coordinator_id }
    $deferring = [System.Collections.Generic.List[object]]::new()
    $stale = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @($Open | Where-Object { $null -ne $_ })) {
        $owner = if ($step.PSObject.Properties['coordinator_id'] -and $step.coordinator_id) { [string]$step.coordinator_id } else { $null }
        if ($null -ne $holder -and $owner -ceq $holder) { $deferring.Add($step) } else { $stale.Add($step) }
    }
    return [pscustomobject]@{ deferring = @($deferring); stale = @($stale) }
}

# Dot-sourcing loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $GuardHost) { throw 'CONTEXT_GUARD_USAGE: -Host claude|codex is required.' }
if (-not $GuardTranscriptPath) { throw 'CONTEXT_GUARD_USAGE: -TranscriptPath is required.' }
$tokens = Get-DtCtxTokens -TranscriptHost $GuardHost -TranscriptPath $GuardTranscriptPath
$result = [pscustomobject][ordered]@{ host = $GuardHost; transcript_path = [System.IO.Path]::GetFullPath($GuardTranscriptPath); tokens = $tokens; found = ($null -ne $tokens) }
if ($GuardJson) { $result | ConvertTo-Json -Compress }
else { if ($null -ne $tokens) { [string]$tokens } else { 'none' } }
