#Requires -Version 7.0
# Roll a run's governing authority forward into ONE current record, so the action-time read set stays
# small by construction (Danny, 2026-10-15: "it really just need to automatically clean up after itself
# and remove anything stale"). Steps, run at each stop/approval transition (managed-resume.md):
#   prepare  split every stop-record original into clauses and write a ledger with one row per clause
#   (decide) the coordinator marks each clause carry or drop; a drop names its reason and checkable evidence
#   compose  build the current record from the carried clauses, verbatim, plus the rollover boundary and
#            the independent reviewer's prompt
#   (review) one read-only -SingleDispatch reviewer confirms every dropped clause is stale
#   verify   prove nothing live was lost: same sources, every clause decided, carried text verbatim,
#            evidence real, review complete
#   install  re-verify, point the checkpoint's STOP at the rollover, rebuild and verify the digest
# Old stop records stay on disk as evidence; they leave the action-time read set. Lifecycle records
# (approvals.json, operator-notes.json, build-state.md, build-plan.md, the checkpoint) are never rolled.
param(
    [Parameter(Mandatory)][ValidateSet('prepare', 'compose', 'verify', 'install')][string]$Action,
    [Parameter(Mandatory)][string]$RunFolder,
    [Parameter(Mandatory)][string]$BuildStatePath,
    # The rollover folder from prepare; prepare creates RUN/authority-rollover/<utc stamp> when omitted.
    [string]$RolloverDirectory,
    # install: write the checkpoint candidate and report, without replacing the live checkpoint.
    [switch]$CandidateOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'authority-digest.ps1')

$script:LifecycleNames = @('approvals.json', 'operator-notes.json', 'build-state.md', 'build-plan.md')
# JSON fields that only wire the authority graph together; the rollover replaces the graph itself.
$script:StructuralKeys = @('schema', 'inherited_authority_sources', 'inherited_boundary', 'inherited_boundary_reference', 'source_disposition', 'scope', 'approval_text', 'approval_record', 'operator_notes', 'required_original_records', 'original_inherited_record_count', 'inherited_originals')
$script:DropReasons = @('consumed', 'superseded', 'closed', 'exhausted')
$script:RecordMarker = '<!-- dt-build authority rollover v1 -->'
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-Sha([string]$Text) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($Text))).ToLowerInvariant() }
function Get-FileSha([string]$Path) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant() }
function Get-Normalized([string]$Text) { ($Text -replace '\s+', ' ').Trim() }
function Get-ClauseId([string]$Text) { 'c-' + (Get-Sha (Get-Normalized $Text)).Substring(0, 12) }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $utf8) }
function Read-Utf8([string]$Path) { ([IO.File]::ReadAllText($Path, $utf8)).TrimStart([char]0xFEFF) }

function Get-RollableSources {
    # The stop-record originals of the current authority graph, from the same discovery the digest uses.
    $null = @(Get-AuthorityInventory -RunFolder $RunFolder -BuildStatePath $BuildStatePath)
    if (-not $script:AuthorityEnumeratedPaths.Count) { throw 'AUTHORITY_ROLLOVER_NO_STOP: the checkpoint names no STOP boundary to roll forward' }
    $checkpoint = [IO.Path]::GetFullPath($BuildStatePath)
    $sources = @($script:AuthorityEnumeratedPaths | Where-Object { $_ -ne $checkpoint -and (Split-Path -Leaf $_) -notin $script:LifecycleNames } | Sort-Object -Unique)
    return [pscustomobject]@{ boundary = $script:AuthorityCurrentBoundary; sources = $sources }
}

function Split-TextClauses([string]$Path, [string]$Text) {
    $clauses = [Collections.Generic.List[object]]::new()
    if ($Text.StartsWith($script:RecordMarker)) {
        # A previous rollover record: its clause markers keep each clause's id-stable text and sources.
        foreach ($m in [regex]::Matches($Text, '(?ms)^<!-- clause (c-[0-9a-f]{12}) \| heading: (.*?) \| sources: (.*?) -->\r?\n(.*?)(?=^<!-- clause |\z)')) {
            $body = $m.Groups[4].Value -replace '(\r?\n)+\z', ''
            $origins = @($m.Groups[3].Value -split '; ' | Where-Object { $_ } | ForEach-Object {
                $at = $_.LastIndexOf('#'); [pscustomobject]@{ path = $_.Substring(0, $at); locator = $_.Substring($at + 1) } })
            $clauses.Add([pscustomobject]@{ text = $body; heading = $m.Groups[2].Value; origins = $origins })
        }
        return $clauses
    }
    $lines = $Text -split '\r?\n'
    $heading = ''; $buffer = [Collections.Generic.List[string]]::new(); $start = 0
    $flush = {
        if ($buffer.Count) {
            $clauses.Add([pscustomobject]@{ text = ($buffer -join "`n"); heading = $heading; origins = @([pscustomobject]@{ path = $Path; locator = "L$start-L$($start + $buffer.Count - 1)" }) })
            $buffer.Clear()
        }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*$') { & $flush; continue }
        if ($line -match '^\s{0,3}#{1,6}\s') { & $flush; $heading = $line.Trim(); continue }
        if ($line -match '^\s*(?:[-*+]|\d+[.)])\s+' -and $buffer.Count) { & $flush }
        if (-not $buffer.Count) { $start = $i + 1 }
        $buffer.Add($line)
    }
    & $flush
    return $clauses
}

function Split-JsonClauses([string]$Path, [string]$Text) {
    $clauses = [Collections.Generic.List[object]]::new()
    $walk = {
        param($Node, [string]$Pointer, [string]$TopKey)
        if ($Node -is [Collections.IDictionary]) {
            foreach ($key in $Node.Keys) { & $walk $Node[$key] "$Pointer/$key" $(if ($TopKey) { $TopKey } else { [string]$key }) }
        }
        elseif ($Node -is [Collections.IList] -and $Node -isnot [string]) {
            for ($i = 0; $i -lt $Node.Count; $i++) { & $walk $Node[$i] "$Pointer/$i" $TopKey }
        }
        elseif ($null -ne $Node) {
            $value = [string]$Node
            $structural = $TopKey -in $script:StructuralKeys
            $clauses.Add([pscustomobject]@{ text = "${Pointer}: $value"; heading = ''; origins = @([pscustomobject]@{ path = $Path; locator = "json:$Pointer" }); structural = $structural })
        }
    }
    $parsed = $Text | ConvertFrom-Json -AsHashtable -Depth 64
    & $walk $parsed '' ''
    # A previous rollover boundary is pure wiring: its live text is the record it points to.
    if ($parsed -is [Collections.IDictionary] -and $parsed['schema'] -eq 'dt-build-authority-rollover/v1') { foreach ($clause in $clauses) { $clause.structural = $true } }
    return $clauses
}

function Get-Clauses([string[]]$Sources) {
    # One row per distinct clause text; identical text in several records keeps every origin.
    $byId = [ordered]@{}
    foreach ($path in $Sources) {
        $text = Read-Utf8 $path
        $parts = if ([IO.Path]::GetExtension($path) -ieq '.json') { Split-JsonClauses $path $text } else { Split-TextClauses $path $text }
        foreach ($part in $parts) {
            $id = Get-ClauseId $part.text
            $structural = [bool]($part.PSObject.Properties['structural'] -and $part.structural)
            if ($byId.Contains($id)) {
                $row = $byId[$id]
                foreach ($origin in $part.origins) { $row.sources += $origin }
                $row.structural = $row.structural -and $structural
                continue
            }
            $byId[$id] = [pscustomobject][ordered]@{ id = $id; text = $part.text; heading = $part.heading; sources = @($part.origins); structural = $structural }
        }
    }
    return @($byId.Values)
}

function Get-Ledger([string]$Directory) {
    $path = Join-Path $Directory 'clauses-ledger.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "AUTHORITY_ROLLOVER_LEDGER_MISSING: $path" }
    return [pscustomobject]@{ path = $path; sha256 = (Get-FileSha $path); data = (Read-Utf8 $path | ConvertFrom-Json -Depth 64) }
}

function Get-RecordText($Ledger, [string]$LedgerSha) {
    $carried = @($Ledger.clauses | Where-Object decision -eq 'carry')
    $dropped = @($Ledger.clauses | Where-Object decision -eq 'drop').Count
    $out = [Text.StringBuilder]::new()
    [void]$out.AppendLine($script:RecordMarker)
    [void]$out.AppendLine('# Current authority (rolled forward)')
    [void]$out.AppendLine()
    [void]$out.AppendLine('Every clause below is carried verbatim from the cited original record. This record adds no authority of its own; it replaces the cited records in the action-time read set. Dropped clauses, each with its reason and evidence, are in the ledger, which is evidence only.')
    [void]$out.AppendLine()
    [void]$out.AppendLine("- ledger: $($Ledger.ledger_path)")
    [void]$out.AppendLine("- ledger_sha256: $LedgerSha")
    [void]$out.AppendLine("- previous_boundary: $($Ledger.previous_boundary)")
    [void]$out.AppendLine("- source_records: $(@($Ledger.sources).Count); clauses carried: $($carried.Count); dropped: $dropped")
    [void]$out.AppendLine()
    foreach ($clause in $carried) {
        $origins = (@($clause.sources | ForEach-Object { "$($_.path)#$($_.locator)" }) -join '; ')
        [void]$out.AppendLine("<!-- clause $($clause.id) | heading: $($clause.heading) | sources: $origins -->")
        [void]$out.AppendLine($clause.text)
        [void]$out.AppendLine()
    }
    return $out.ToString()
}

function Get-BoundaryText($Ledger, [string]$LedgerSha, [string]$RecordPath) {
    $boundary = [ordered]@{
        schema = 'dt-build-authority-rollover/v1'
        operation = 'authority-rollover'
        note = 'Rolled-forward authority: the record below carries every live clause of the previous graph verbatim. Grants no new authority.'
        inherited_authority_sources = @($RecordPath)
        source_disposition = $RecordPath
        scope = $RecordPath
        approval_text = $RecordPath
        required_original_records = 2
        original_inherited_record_count = 1
        previous_boundary = $Ledger.previous_boundary
        ledger = $Ledger.ledger_path
        ledger_sha256 = $LedgerSha
    }
    return ($boundary | ConvertTo-Json -Depth 5)
}

function Get-ReviewPromptText($Ledger, [string]$LedgerSha) {
    $dropped = @($Ledger.clauses | Where-Object decision -eq 'drop')
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Independent authority-rollover review')
    $lines.Add('')
    $lines.Add("You are an independent, read-only reviewer. The ledger at $($Ledger.ledger_path) (sha256 $LedgerSha) lists every clause of a dt-build run's governing stop records with a carry or drop decision. Dropped clauses leave the action-time authority the build reads before acting, so a live clause dropped by mistake would silently remove a restriction, pin, gate, allowance or exclusion.")
    $lines.Add('')
    $lines.Add("For each dropped clause below, read its text, its reason and its evidence in the ledger, and check them against the run's records under $RunFolder. Answer stale only when the clause is plainly consumed, superseded, closed or exhausted by that evidence; when in doubt, answer live. Do not edit any file.")
    $lines.Add('')
    $lines.Add('Reply with only this JSON, no prose and no code fence:')
    $lines.Add("{""ledger_sha256"": ""$LedgerSha"", ""verdicts"": [{""clause"": ""<id>"", ""verdict"": ""stale"" or ""live"", ""why"": ""<one sentence>""}]}")
    $lines.Add('')
    $lines.Add("Dropped clauses ($($dropped.Count)):")
    foreach ($clause in $dropped) { $lines.Add("- $($clause.id) ($($clause.reason))") }
    return ($lines -join "`n") + "`n"
}

function Test-Evidence($Clause, $Ledger, [string]$EventsPath) {
    $evidence = $Clause.evidence
    if ($null -eq $evidence) { return 'no evidence' }
    $names = @($evidence.PSObject.Properties.Name)
    if ($names -contains 'quote') {
        $quote = [string]$evidence.quote.text
        $path = [string]$evidence.quote.path
        if ((Get-Normalized $quote).Length -lt 12) { return 'quote shorter than 12 characters' }
        $full = if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $RunFolder $path }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return "quoted file missing: $path" }
        if (-not (Get-Normalized (Read-Utf8 $full)).Contains((Get-Normalized $quote))) { return "quote not found in $path" }
        return $null
    }
    if ($names -contains 'event_seq') {
        if (-not (Test-Path -LiteralPath $EventsPath)) { return 'jobs/events.jsonl missing' }
        $seq = [int]$evidence.event_seq
        $found = Select-String -LiteralPath $EventsPath -Pattern ('"seq":' + $seq + ',') -SimpleMatch -Quiet
        if (-not $found) { return "event seq $seq not in jobs/events.jsonl" }
        return $null
    }
    if ($names -contains 'clause') {
        $target = @($Ledger.clauses | Where-Object id -eq ([string]$evidence.clause))
        if ($target.Count -ne 1 -or $target[0].decision -ne 'carry') { return "superseding clause $($evidence.clause) is not a carried clause" }
        return $null
    }
    return 'evidence must be quote {path,text}, event_seq, or clause'
}

function Invoke-Verify([string]$Directory) {
    $errors = [Collections.Generic.List[string]]::new()
    $ledger = Get-Ledger $Directory
    $data = $ledger.data
    $current = Get-RollableSources
    # 1. The same authority graph: same boundary, same originals, unchanged since prepare.
    if ([IO.Path]::GetFullPath([string]$data.previous_boundary) -ne [IO.Path]::GetFullPath([string]$current.boundary)) { $errors.Add("STOP boundary changed since prepare: $($current.boundary)") }
    $ledgerPaths = @($data.sources | ForEach-Object { [IO.Path]::GetFullPath([string]$_.path) } | Sort-Object)
    $livePaths = @($current.sources | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object)
    if (($ledgerPaths -join '|') -ne ($livePaths -join '|')) { $errors.Add('the authority graph has different originals than the ledger') }
    foreach ($source in $data.sources) {
        if (-not (Test-Path -LiteralPath $source.path)) { $errors.Add("source missing: $($source.path)"); continue }
        if ((Get-FileSha $source.path) -ne $source.sha256) { $errors.Add("source changed since prepare: $($source.path)") }
    }
    # 2. Every clause, exactly as extracted, with a valid decision.
    $fresh = @(Get-Clauses $livePaths)
    $freshById = @{}; foreach ($row in $fresh) { $freshById[$row.id] = $row }
    $ledgerIds = @($data.clauses | ForEach-Object id)
    if ((@($fresh.id | Sort-Object) -join '|') -ne (@($ledgerIds | Sort-Object) -join '|')) { $errors.Add('ledger clauses differ from a fresh extraction of the sources') }
    $eventsPath = Join-Path $RunFolder 'jobs/events.jsonl'
    foreach ($clause in $data.clauses) {
        $row = $freshById[[string]$clause.id]
        if ($row -and $row.text -cne [string]$clause.text) { $errors.Add("$($clause.id): ledger text differs from the source") }
        switch ([string]$clause.decision) {
            'carry' { }
            'structural' { if (-not ($row -and $row.structural)) { $errors.Add("$($clause.id): only graph-wiring JSON fields may be structural") } }
            'drop' {
                if ([string]$clause.reason -notin $script:DropReasons) { $errors.Add("$($clause.id): drop reason must be one of $($script:DropReasons -join ', ')") }
                $problem = Test-Evidence $clause $data $eventsPath
                if ($problem) { $errors.Add("$($clause.id): $problem") }
            }
            default { $errors.Add("$($clause.id): no decision (carry or drop)") }
        }
    }
    # 3. The record, boundary and review prompt are exactly what compose produces from this ledger.
    $recordPath = Join-Path $Directory 'current-authority.md'
    $boundaryPath = Join-Path $Directory 'next-operation-boundary.json'
    $promptPath = Join-Path $Directory 'review-prompt.md'
    foreach ($pair in @(@($recordPath, (Get-RecordText $data $ledger.sha256)), @($boundaryPath, (Get-BoundaryText $data $ledger.sha256 $recordPath)), @($promptPath, (Get-ReviewPromptText $data $ledger.sha256)))) {
        if (-not (Test-Path -LiteralPath $pair[0])) { $errors.Add("compose output missing: $($pair[0])"); continue }
        if ((Read-Utf8 $pair[0]) -cne $pair[1]) { $errors.Add("$(Split-Path -Leaf $pair[0]) differs from compose output for this ledger") }
    }
    # 4. One independent read-only single-dispatch review confirms every drop.
    $dropIds = @($data.clauses | Where-Object decision -eq 'drop' | ForEach-Object id)
    $reviewPath = Join-Path $Directory 'review.json'
    $provenancePath = "$reviewPath.provenance.json"
    if ($dropIds.Count) {
        if (-not (Test-Path -LiteralPath $reviewPath) -or -not (Test-Path -LiteralPath $provenancePath)) { $errors.Add('independent review missing: run one reviewer with -SingleDispatch -ReadOnly -AdHoc -PromptPath review-prompt.md -OutputPath review.json') }
        else {
            $provenance = Read-Utf8 $provenancePath | ConvertFrom-Json
            if (-not $provenance.pass) { $errors.Add('review dispatch did not pass') }
            if (-not ($provenance.PSObject.Properties['single_dispatch'] -and $provenance.single_dispatch)) { $errors.Add('review was not dispatched with -SingleDispatch') }
            if ($provenance.output_sha256 -ne (Get-FileSha $reviewPath)) { $errors.Add('review.json differs from the reviewer output its provenance records') }
            if ((Test-Path -LiteralPath $promptPath) -and $provenance.prompt_sha256 -ne (Get-FileSha $promptPath)) { $errors.Add('review used a different prompt than review-prompt.md') }
            $reviewText = (Read-Utf8 $reviewPath).Trim() -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
            try { $review = $reviewText | ConvertFrom-Json -Depth 16 } catch { $review = $null; $errors.Add('review.json is not JSON') }
            if ($review) {
                if ($review.ledger_sha256 -ne $ledger.sha256) { $errors.Add('review names a different ledger') }
                $verdicts = @{}; foreach ($v in @($review.verdicts)) { $verdicts[[string]$v.clause] = [string]$v.verdict }
                foreach ($id in $dropIds) {
                    if (-not $verdicts.ContainsKey($id)) { $errors.Add("review has no verdict for dropped clause $id") }
                    elseif ($verdicts[$id] -ne 'stale') { $errors.Add("reviewer says dropped clause $id is $($verdicts[$id])") }
                }
            }
        }
    }
    $recordChars = if (Test-Path -LiteralPath $recordPath) { (Read-Utf8 $recordPath).Length } else { 0 }
    return [pscustomobject][ordered]@{
        pass = ($errors.Count -eq 0)
        errors = @($errors)
        rollover_directory = $Directory
        ledger_sha256 = $ledger.sha256
        source_records = @($data.sources).Count
        source_chars = [long](@($data.sources | ForEach-Object { [long]$_.chars }) | Measure-Object -Sum).Sum
        clauses = @($data.clauses).Count
        carried = @($data.clauses | Where-Object decision -eq 'carry').Count
        dropped = $dropIds.Count
        record_chars = $recordChars
    }
}

$RunFolder = [IO.Path]::GetFullPath($RunFolder)
$BuildStatePath = [IO.Path]::GetFullPath($BuildStatePath)
switch ($Action) {
    'prepare' {
        $current = Get-RollableSources
        if (-not $RolloverDirectory) { $RolloverDirectory = Join-Path $RunFolder ('authority-rollover/' + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')) }
        $RolloverDirectory = [IO.Path]::GetFullPath($RolloverDirectory)
        if (Test-Path -LiteralPath (Join-Path $RolloverDirectory 'clauses-ledger.json')) { throw "AUTHORITY_ROLLOVER_EXISTS: $RolloverDirectory already has a ledger" }
        [IO.Directory]::CreateDirectory($RolloverDirectory) | Out-Null
        $clauses = @(Get-Clauses $current.sources | ForEach-Object {
            [pscustomobject][ordered]@{ id = $_.id; text = $_.text; heading = $_.heading; sources = @($_.sources); decision = $(if ($_.structural) { 'structural' } else { $null }); reason = $null; evidence = $null }
        })
        $ledgerPath = Join-Path $RolloverDirectory 'clauses-ledger.json'
        $ledger = [ordered]@{
            schema = 'dt-build-authority-rollover-ledger/v1'
            run_folder = $RunFolder
            checkpoint = $BuildStatePath
            prepared_at_utc = [datetime]::UtcNow.ToString('o')
            ledger_path = $ledgerPath
            previous_boundary = $current.boundary
            decision_rules = "Set decision to carry or drop on every clause whose decision is null. A drop needs reason ($($script:DropReasons -join '|')) and evidence: {quote:{path,text}} found in that file, {event_seq:N} in jobs/events.jsonl, or {clause:'c-...'} naming the carried clause that supersedes it. Carry when in doubt. Never edit id, text, heading or sources."
            sources = @($current.sources | ForEach-Object { [ordered]@{ path = $_; sha256 = (Get-FileSha $_); chars = (Read-Utf8 $_).Length } })
            clauses = $clauses
        }
        Write-Utf8 $ledgerPath ($ledger | ConvertTo-Json -Depth 32)
        [ordered]@{ status = 'prepared'; rollover_directory = $RolloverDirectory; ledger = $ledgerPath; source_records = $current.sources.Count; clauses = $clauses.Count; to_decide = @($clauses | Where-Object { $null -eq $_.decision }).Count; next = 'decide every null clause in the ledger, then -Action compose' } | ConvertTo-Json -Compress
    }
    'compose' {
        if (-not $RolloverDirectory) { throw 'AUTHORITY_ROLLOVER_DIRECTORY: pass -RolloverDirectory from prepare' }
        $ledger = Get-Ledger $RolloverDirectory
        $undecided = @($ledger.data.clauses | Where-Object { [string]$_.decision -notin @('carry', 'drop', 'structural') })
        if ($undecided.Count) { throw "AUTHORITY_ROLLOVER_UNDECIDED: $($undecided.Count) clause(s) have no carry/drop decision, first $($undecided[0].id)" }
        $recordPath = Join-Path $RolloverDirectory 'current-authority.md'
        Write-Utf8 $recordPath (Get-RecordText $ledger.data $ledger.sha256)
        Write-Utf8 (Join-Path $RolloverDirectory 'next-operation-boundary.json') (Get-BoundaryText $ledger.data $ledger.sha256 $recordPath)
        Write-Utf8 (Join-Path $RolloverDirectory 'review-prompt.md') (Get-ReviewPromptText $ledger.data $ledger.sha256)
        [ordered]@{ status = 'composed'; record = $recordPath; record_chars = (Read-Utf8 $recordPath).Length; dropped = @($ledger.data.clauses | Where-Object decision -eq 'drop').Count; next = 'dispatch one reviewer: invoke-codex-chunk.ps1 (or invoke-claude-chunk.ps1) -ReadOnly -AdHoc -SingleDispatch -PromptPath review-prompt.md -OutputPath review.json, then -Action verify' } | ConvertTo-Json -Compress
    }
    'verify' {
        if (-not $RolloverDirectory) { throw 'AUTHORITY_ROLLOVER_DIRECTORY: pass -RolloverDirectory from prepare' }
        $result = Invoke-Verify ([IO.Path]::GetFullPath($RolloverDirectory))
        $result | ConvertTo-Json -Depth 6 -Compress
        if (-not $result.pass) { exit 1 }
    }
    'install' {
        if (-not $RolloverDirectory) { throw 'AUTHORITY_ROLLOVER_DIRECTORY: pass -RolloverDirectory from prepare' }
        $RolloverDirectory = [IO.Path]::GetFullPath($RolloverDirectory)
        $result = Invoke-Verify $RolloverDirectory
        if (-not $result.pass) { $result | ConvertTo-Json -Depth 6 -Compress; exit 1 }
        $checkpointText = Read-Utf8 $BuildStatePath
        $stopLine = [regex]::Match($checkpointText, '(?m)^(\s*(?:-\s*)?)STOP=.*$')
        if (-not $stopLine.Success) { throw 'AUTHORITY_ROLLOVER_NO_STOP: the checkpoint has no STOP= line to repoint' }
        $candidate = $checkpointText.Substring(0, $stopLine.Index) + $stopLine.Groups[1].Value + 'STOP=' + $RolloverDirectory.Replace('\', '/') + $checkpointText.Substring($stopLine.Index + $stopLine.Length)
        $candidatePath = Join-Path $RolloverDirectory 'checkpoint-candidate.md'
        Write-Utf8 $candidatePath $candidate
        # What the action-time read set becomes, and any pre-rollover original the checkpoint still requires.
        $null = @(Get-AuthorityInventory -RunFolder $RunFolder -BuildStatePath $candidatePath)
        $after = @(Get-AuthorityInventory -RunFolder $RunFolder -BuildStatePath $candidatePath)
        $oldSources = @((Get-Ledger $RolloverDirectory).data.sources | ForEach-Object { [IO.Path]::GetFullPath([string]$_.path) })
        $stillRequired = @($after | Where-Object { [IO.Path]::GetFullPath($_.path) -in $oldSources } | ForEach-Object path)
        $report = [ordered]@{
            status = $(if ($CandidateOnly) { 'candidate' } else { 'installed' })
            rollover_directory = $RolloverDirectory
            checkpoint_candidate = $candidatePath
            read_set_originals = $after.Count
            read_set_chars = [long](@($after | ForEach-Object { [long]$_.chars }) | Measure-Object -Sum).Sum
            previous_source_records = $result.source_records
            previous_source_chars = $result.source_chars
            still_required_old_records = $stillRequired
        }
        if (-not $CandidateOnly) {
            # Append-only audit history: every dropped clause verbatim, with its source, why it is stale and
            # what superseded it. Evidence only: never read before an action, never discovered as authority.
            $historyPath = Join-Path $RunFolder 'authority-history.jsonl'
            $ledger = Get-Ledger $RolloverDirectory
            $already = (Test-Path -LiteralPath $historyPath) -and (Select-String -LiteralPath $historyPath -Pattern ('"ledger_sha256":"' + $ledger.sha256 + '"') -SimpleMatch -Quiet)
            if (-not $already) {
                $review = @{}
                $reviewPath = Join-Path $RolloverDirectory 'review.json'
                if (Test-Path -LiteralPath $reviewPath) {
                    $reviewText = (Read-Utf8 $reviewPath).Trim() -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
                    foreach ($v in @(($reviewText | ConvertFrom-Json -Depth 16).verdicts)) { $review[[string]$v.clause] = [string]$v.why }
                }
                $shaByPath = @{}; foreach ($s in $ledger.data.sources) { $shaByPath[[IO.Path]::GetFullPath([string]$s.path)] = $s.sha256 }
                $rolledAt = [datetime]::UtcNow.ToString('o')
                $rows = foreach ($clause in @($ledger.data.clauses | Where-Object decision -eq 'drop')) {
                    [ordered]@{
                        rolled_at_utc = $rolledAt; rollover_directory = $RolloverDirectory; ledger_sha256 = $ledger.sha256
                        clause = $clause.id; heading = $clause.heading; text = $clause.text; reason = $clause.reason; superseded_by = $clause.evidence
                        reviewer_why = $review[[string]$clause.id]
                        sources = @($clause.sources | ForEach-Object { [ordered]@{ path = $_.path; locator = $_.locator; sha256 = $shaByPath[[IO.Path]::GetFullPath([string]$_.path)] } })
                    } | ConvertTo-Json -Depth 12 -Compress
                }
                if (@($rows).Count) { [IO.File]::AppendAllText($historyPath, ((@($rows) -join "`n") + "`n"), $utf8) }
            }
            $report.history = $historyPath
            $write = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'write-resume-checkpoint.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -ContentPath $candidatePath 2>&1
            if ($LASTEXITCODE -ne 0) { throw "AUTHORITY_ROLLOVER_CHECKPOINT: $($write -join ' ')" }
            $build = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'build-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath 2>&1
            if ($LASTEXITCODE -ne 0) { throw "AUTHORITY_ROLLOVER_DIGEST: $($build -join ' ')" }
            $verifyDigest = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath 2>&1
            if ($LASTEXITCODE -ne 0) { throw "AUTHORITY_ROLLOVER_DIGEST_VERIFY: $($verifyDigest -join ' ')" }
            $report.checkpoint_write = ($write -join ' ')
        }
        $report | ConvertTo-Json -Depth 6 -Compress
    }
}
