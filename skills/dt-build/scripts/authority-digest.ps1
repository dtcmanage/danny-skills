#Requires -Version 7.0
# Shared deterministic authority inventory. No model calls, no authorization decisions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AuthorityReadBudgetChars = 32000
$script:AuthorityReadCeilingChars = 96000
# Used only to verify a pre-2.60 pinned manifest before a classification-only migration.
$script:AuthorityLegacyArtifactKinds = $false
$script:AuthorityLegacyLifecycleLocators = $false

# Evidence-only files: named in authority text but never authority. authority-history.jsonl is the
# rollover's append-only audit log, and the provenance sidecar, consolidations file and clause ledger are
# its working evidence (roll-authority-forward.ps1); each is read only for an explicit lookup.
$script:AuthorityEvidenceOnlyNames = @('evidence-notes.json', 'authority-history.jsonl', 'current-authority.provenance.json', 'consolidations.json', 'clauses-ledger.json')
$script:AuthorityRunRootNames = @('approvals.json', 'operator-notes.json', 'build-state.md', 'build-plan.md')

function Get-AuthorityHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# The checkpoint (_build-state.md) is live state that every coordinator rewrites at rotation, and the lean
# checkpoint contract forbids pinning it by full-file hash (managed-resume.md). Only its authority-bearing
# text is pinned and scanned for originals: every line outside a state section (Restrictions, Pointers, Run,
# Artifacts, unknown headings, a flat checkpoint) except rotating key lines, plus the authority pointers a
# compressed checkpoint keeps inside a state section: alias definitions (STOP=..., RUN=...) and lines that
# direct a bootstrap read (bootstrap, IN FULL). Progress, next-step, git and evidence prose is not authority.
$script:AuthorityCheckpointStateHeadings = '(?i)^(?:progress|completed|in[ -]?flight|next steps?|git|evidence|milestones|chunks(?:\s*\(.*\))?|handoff|status|current state)$'
# Lower-case key lines a coordinator or dt-job rewrites as it goes (status, cursor, timestamp, position).
$script:AuthorityCheckpointStateKeys = '^(?:run_status|last_consumed_event_seq|updated_utc|status_line|status|phase|current_milestone|last_commit_sha):'

function Test-AuthorityLifecycleLocator {
    param([string]$Path, [string]$Line)
    return (-not $script:AuthorityLegacyLifecycleLocators -and
        (Split-Path -Leaf $Path) -in @('build-plan.md', 'build-state.md') -and
        $Line -match '^(?:roadmap|design|plan)_path:\s*[^\r\n]+$' -and
        $Line -notmatch '(?i)IN FULL|before\s*bootstrap')
}

function Test-AuthorityContextDocument {
    param([string]$Path)
    $relative = $Path.Replace('\', '/')
    return $relative -match '(?i)/_Claude-Workspace/(?:UNIFIED-MEMORY\.md|TCM Tech Stack Reference\.md|00_Resources/model-routing\.md)$' -or
        (Split-Path -Leaf $Path) -in @('source-evidence.md', 'launch-evidence.md')
}
$script:AuthorityCheckpointPointerLine = '^\s*(?:[-*]\s*)?[A-Z][A-Z0-9_]*=|(?i:bootstrap)|IN FULL'

function Get-AuthorityCheckpointText {
    param([string]$Text)
    $kept = [Collections.Generic.List[string]]::new()
    $state = $false; $fenced = $false
    foreach ($line in ($Text.Replace("`r`n", "`n") -split "`n")) {
        if ($line -match '^\s*(?:```|~~~)') { $fenced = -not $fenced }
        elseif (-not $fenced -and $line -match '^#{1,6}\s+(.+?)\s*#*\s*$') {
            $state = $Matches[1].Trim().TrimEnd(':') -match $script:AuthorityCheckpointStateHeadings
            if (-not $state) { $kept.Add($line) }
            continue
        }
        if ($line -cmatch $script:AuthorityCheckpointStateKeys) { continue }
        if ($state -and $line -cnotmatch $script:AuthorityCheckpointPointerLine) { continue }
        $kept.Add($line)
    }
    return ($kept -join "`n")
}

function Get-AuthorityCheckpointHash {
    param([string]$Text)
    # Hash only the authority-bearing checkpoint text (Get-AuthorityCheckpointText): resume, rotation and
    # consume may rewrite status, cursor, progress, git and next-step state after the digest is built.
    $authority = Get-AuthorityCheckpointText $Text
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($authority))).ToLowerInvariant()
}

function Get-AuthorityAliases {
    param([string]$Text)
    $aliases = @{}
    foreach ($m in [regex]::Matches($Text, '(?m)^\s*(?:-\s*)?([A-Z][A-Z0-9_]*)=([^\r\n]+)')) {
        $value = $m.Groups[2].Value.Trim()
        # Values retain spaces to end of list item. Compressed alias-reference
        # definitions sometimes append an explicit sentence or unchanged-seal annotation.
        if (-not [IO.Path]::IsPathRooted($value)) {
            $value = ([regex]::new('(?i)\.\s+(?=Before\s*bootstrap\b)|\s+(?=unchanged\w*\b)').Split($value, 2))[0].TrimEnd('.')
        }
        $aliases[$m.Groups[1].Value] = $value
    }
    return $aliases
}

function Resolve-AuthorityLiteral {
    param([string]$Literal, [string]$Source, [string]$RunFolder, [hashtable]$Aliases, [switch]$NamedOriginal)
    $value = $Literal.Trim().Replace('/', [IO.Path]::DirectorySeparatorChar)
    $visited = @{}
    while ($value -match '^([A-Z][A-Z0-9_]*)[/\\](.*)$' -and $Aliases.ContainsKey($Matches[1])) {
        $name = $Matches[1]; $tail = $Matches[2]
        if ($visited.ContainsKey($name)) { throw "AUTHORITY_ALIAS_CYCLE: $Literal" }
        $visited[$name] = $true
        $value = Join-Path $Aliases[$name] $tail
    }
    if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
    $near = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Source) $value))
    try {
        if (Test-Path -LiteralPath $near) { return $near }
    } catch [IO.PathTooLongException] {
        # Prose can produce unprobeable candidates. Still check whether the parent
        # identifies a real source directory before treating the reference as unresolved.
    }
    if ($value -in ($script:AuthorityRunRootNames + $script:AuthorityEvidenceOnlyNames)) { return [IO.Path]::GetFullPath((Join-Path $RunFolder $value)) }
    # A named original below an existing source directory still fails closed if deleted.
    # Unresolved repository/prose locators must not become invented run-relative originals.
    if ($NamedOriginal) { return $near }
    try {
        if (Test-Path -LiteralPath (Split-Path -Parent $near) -PathType Container) { return $near }
    } catch [IO.PathTooLongException] {
        return $null
    }
    return $null
}

function Get-AuthorityCandidates {
    param([string]$Text, [hashtable]$Aliases)
    # jsonl before json: the alternation must not cut authority-history.jsonl down to .json.
    $ext = '(?:md|jsonl|json|txt|ya?ml)'
    $patterns = @(
        ('`(?<path>[^`\r\n]+\.' + $ext + ')`'),
        ('\]\(<?(?<path>[^\r\n<>]+\.' + $ext + ')>?\)'),
        ('"(?<path>[^"\r\n]+\.' + $ext + ')"'),
        # FS-132: an absolute path may contain spaces but never runs past another file's extension
        # followed by space or punctuation (e.g. "errors.log). Detail: x.md" is two tokens).
        ('(?<![\w])(?<path>[a-zA-Z]:[\\/](?:(?!\.[A-Za-z0-9]{1,5}[)\],;.:]{0,2}\s)[^`"<>|\r\n])*?\.' + $ext + ')(?=[\s,;.)\]]|$)'),
        # Single-quoted paths may hold spaces; an apostrophe inside a word (Danny's) never opens one.
        ("(?<![\w'])'(?<path>[^'`\r\n]+\." + $ext + ")'(?![\w'])"),
        # A POSIX absolute path follows the same rule as a drive path (spaces allowed, never past another
        # file's extension); a spaced match must name an existing directory, else it falls to the next pattern.
        ('(?<![\w.:~/\\-])(?<path>/(?:(?!\.[A-Za-z0-9]{1,5}[)\],;.:]{0,2}\s)[^`"''<>|\r\n])*?\.' + $ext + ')(?=[\s,;.)\]]|$)'),
        ('(?<![\w:/\\])(?<path>(?:[\w.-]+[\\/])+[\w.-]+\.' + $ext + ')')
    )
    if ($Aliases.Count) {
        $names = ($Aliases.Keys | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|'
        # A known alias can start after a glued prose word, but never in a path segment.
        $patterns = @('(?<![/\\])(?<path>(?:' + $names + ')[/\\](?:[^\s`"<>|{},;]+[/\\])?\{[^}\r\n]+\}|(?:' + $names + ')[/\\][^\s`"<>|{},;]*?\.' + $ext + ')') + $patterns
    }
    $occupied = [Collections.Generic.List[object]]::new()
    foreach ($pattern in $patterns) {
        foreach ($m in [regex]::Matches($Text, $pattern)) {
            $g = $m.Groups['path']
            if (@($occupied | Where-Object { $g.Index -lt $_.end -and ($g.Index + $g.Length) -gt $_.start }).Count) { continue }
            if ($pattern.StartsWith('(?<![\w.:~/') -and $g.Value -match '\s' -and -not (Test-Path -LiteralPath (Split-Path -Parent $g.Value) -PathType Container)) { continue }
            $occupied.Add(@{ start = $g.Index; end = $g.Index + $g.Length })
            $literal = $g.Value
            if ($pattern.StartsWith('"')) { $literal = ('"' + $literal + '"') | ConvertFrom-Json }
            if ($literal -match '^[a-z]+://' -or $literal -match '(?:^|[/\\])authority-digest\.(md|json)$') { continue }
            $expanded = @($literal)
            if ($literal -match '^(.*)\{([^{}]*,[^{}]*)\}(.*)$') {
                $prefix = $Matches[1]; $suffix = $Matches[3]
                $expanded = @($Matches[2] -split ',' | ForEach-Object { $prefix + $_.Trim() + $suffix })
            }
            foreach ($item in $expanded) { [pscustomobject]@{ literal = $item; index = $g.Index; explicit = ($pattern.StartsWith('`') -or $pattern.StartsWith('\]') -or $pattern.StartsWith('"') -or $pattern.StartsWith("(?<![\w'])'")) } }
            # Compressed lists often give the directory only on the first member.
            if ($literal -match '^(.*[/\\])[^/\\]+\.' + $ext + '$') {
                $directoryPrefix = $Matches[1]
                $rest = $Text.Substring($g.Index + $g.Length)
                foreach ($sibling in [regex]::Matches($rest, '\G,\s*(?<file>[\w.-]+\.' + $ext + ')')) {
                    [pscustomobject]@{ literal = $directoryPrefix + $sibling.Groups['file'].Value; index = $g.Index + $g.Length + $sibling.Index; explicit = $true }
                }
            }
        }
    }
}

function Get-AuthorityEnumeration {
    param([string]$Boundary, [string]$RunFolder, [hashtable]$Aliases, [hashtable]$Stack = @{})
    if ($Stack.ContainsKey($Boundary)) { throw "AUTHORITY_INHERITANCE_CYCLE: $Boundary" }
    $Stack[$Boundary] = $true
    if (-not (Test-Path -LiteralPath $Boundary -PathType Leaf)) {
        $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $Boundary; candidate = $Boundary; resolved = $Boundary; reason = 'missing_named_original'; required = $true })
        throw "AUTHORITY_MISSING: $Boundary"
    }
    $json = [IO.File]::ReadAllText($Boundary) | ConvertFrom-Json
    $inherited = @()
    if ($json.PSObject.Properties['inherited_boundary']) {
        $parent = Resolve-AuthorityLiteral $json.inherited_boundary $Boundary $RunFolder $Aliases -NamedOriginal
        $inherited = @(Get-AuthorityEnumeration $parent $RunFolder $Aliases $Stack)
    } elseif ($json.PSObject.Properties['inherited_authority_sources']) {
        $inherited = @($json.inherited_authority_sources | ForEach-Object { Resolve-AuthorityLiteral $_ $Boundary $RunFolder $Aliases -NamedOriginal })
    } else { throw "AUTHORITY_ENUMERATION_MISSING: $Boundary" }
    $paths = @($Boundary) + $inherited
    foreach ($field in @('source_disposition', 'scope', 'approval_text')) {
        if (-not $json.PSObject.Properties[$field]) { throw "AUTHORITY_ENUMERATION_FIELD: $Boundary : $field" }
        $paths += Resolve-AuthorityLiteral $json.$field $Boundary $RunFolder $Aliases -NamedOriginal
    }
    $paths = @($paths | Sort-Object -Unique)
    foreach ($field in @('original_inherited_record_count', 'inherited_originals')) {
        if ($json.PSObject.Properties[$field] -and [int]$json.$field -ne $inherited.Count) { throw "AUTHORITY_ENUMERATION_COUNT: $Boundary : $field" }
    }
    if (-not $json.PSObject.Properties['required_original_records'] -or [int]$json.required_original_records -ne $paths.Count) { throw "AUTHORITY_ENUMERATION_COUNT: $Boundary : required_original_records" }
    $Stack.Remove($Boundary)
    return $paths
}

function Get-AuthorityReferenceWaiver {
    param([string]$Text, $Candidate, [string]$Source, [string]$Checkpoint, [string]$RunFolder, [string]$Resolved)
    # Only the filename in the pipeline template's provenance sentence is a shape name.
    # Do not discard comments generally: comments can contain operative restrictions/pointers.
    if ($Source -eq $Checkpoint -and $Candidate.literal -ceq '_build-state.md') {
        foreach ($comment in [regex]::Matches($Text, '(?s)<!--\s*Canonical `(?<path>_build-state\.md)` shape\..*?-->')) {
            if ($Candidate.index -eq $comment.Groups['path'].Index) { return 'checkpoint_template_shape' }
        }
    }
    # Legacy planning documents mix local originals with host-qualified operational evidence.
    # Require an adjacent host qualifier, not just an authority/evidence word or a missing file.
    # Boundaries, approvals, explicit full-read directives and local planning/run paths stay closed.
    if ((Split-Path -Leaf $Source) -notmatch '(?i)^(?:design-final|plan-draft|roadmap|build-plan|build-input)' -or
        -not [IO.Path]::IsPathFullyQualified($Candidate.literal)) { return $null }
    foreach ($directory in @((Split-Path -Parent $Checkpoint), $RunFolder)) {
        $prefix = [IO.Path]::GetFullPath($directory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($Resolved.StartsWith($prefix, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) { return $null }
    }
    $before = ($Text.Substring(0, $Candidate.index) -split '\r?\n')[-1]
    $after = ($Text.Substring($Candidate.index + $Candidate.literal.Length) -split '\r?\n')[0]
    $line = $before + $Candidate.literal + $after
    if ($line -match '(?i)\bIN FULL\b|before\s*bootstrap|\bread\b[^.!?]*\boriginal\b|\b(?:governing|named)\s+(?:authority|original)\b') { return $null }
    $hostName = '(?:CT|VM)[0-9]+'
    if ($after -match ('(?i)^[`"''>]*\s+on\s+`?' + $hostName + '`?(?=[\s.,;:)]|$)') -or
        $before -match ('(?i)\b`?' + $hostName + '`?\s*:\s*[`"''<]*$')) { return 'remote_host_evidence' }
    return $null
}

function Get-AuthorityInventory {
    param([string]$RunFolder, [string]$BuildStatePath)
    $root = [IO.Path]::GetFullPath($RunFolder)
    $checkpoint = [IO.Path]::GetFullPath($BuildStatePath)
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($checkpoint)
    $script:AuthorityDiagnostics = [Collections.Generic.List[object]]::new()
    $script:AuthorityCurrentBoundary = $null
    $script:AuthorityEnumeratedPaths = @()
    $script:AuthorityCheckpointFullReads = @()
    $script:AuthorityArtifactPaths = @()
    $checkpointText = [IO.File]::ReadAllText($checkpoint)
    $aliases = Get-AuthorityAliases $checkpointText
    # Paths named only in rotating state sections (progress, next step, evidence) are not authority.
    $checkpointAuthorityText = Get-AuthorityCheckpointText ($checkpointText.TrimStart([char]0xFEFF))
    $checkpointCandidates = @(Get-AuthorityCandidates $checkpointAuthorityText $aliases | Sort-Object index)
    # STOP is the explicit current authority locator in compressed checkpoints.
    if ($aliases.ContainsKey('STOP')) {
        $boundary = Resolve-AuthorityLiteral 'STOP/next-operation-boundary.json' $checkpoint $root $aliases
        $script:AuthorityEnumeratedPaths = @(Get-AuthorityEnumeration $boundary $root $aliases)
        $script:AuthorityCurrentBoundary = $boundary
        foreach ($original in $script:AuthorityEnumeratedPaths) { $pending.Enqueue($original) }
    }
    foreach ($name in $script:AuthorityRunRootNames) {
        $path = Join-Path $root $name
        if ($script:AuthorityEnumeratedPaths.Count -or (Test-Path -LiteralPath $path -PathType Leaf)) { $pending.Enqueue($path) }
    }
    $seen = @{}
    $records = [Collections.Generic.List[object]]::new()
    $missing = [Collections.Generic.List[string]]::new()
    while ($pending.Count) {
        $path = $pending.Dequeue()
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if ((Split-Path -Leaf $path) -in $script:AuthorityEvidenceOnlyNames) {
            $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $checkpoint; candidate = $path; resolved = $path; reason = 'evidence_only'; required = $false })
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $missing.Add($path)
            $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $checkpoint; candidate = $path; resolved = $path; reason = 'missing_named_original'; required = $true })
            continue
        }
        $originalBytes = [IO.File]::ReadAllBytes($path)
        $text = [Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xFEFF)
        if ($path -eq $checkpoint) { $text = $checkpointAuthorityText }
        $leaf = Split-Path -Leaf $path
        # An implementation artifact locator is navigation, not a legacy stop boundary. Keep it pinned
        # and indexed, and retain explicit full-read directives/current structured boundaries.
        $isImplementation = $false
        foreach ($artifactLocator in [regex]::Matches($checkpointAuthorityText, '(?m)^(?:roadmap|design|plan)_path:\s*(.+)$')) {
            $locator = $artifactLocator.Groups[1].Value.Trim().Trim('`', '"', "'")
            if (-not [IO.Path]::IsPathFullyQualified($locator)) { $locator = Join-Path (Split-Path -Parent $checkpoint) $locator }
            $locator = [IO.Path]::GetFullPath($locator)
            if ($locator -notin $script:AuthorityArtifactPaths) { $script:AuthorityArtifactPaths += $locator }
            if ($locator -eq $path) { $isImplementation = $true }
        }
        # Explicit inherited sources and lifecycle plans can never become deferred artifacts.
        if ($path -in $script:AuthorityEnumeratedPaths -or $leaf -eq 'build-plan.md') { $isImplementation = $false }
        $kind = if ($path -eq $checkpoint) { 'checkpoint' } elseif ($leaf -match 'approval' -or $path -match '[/\\]approvals[/\\]') { 'approval' } elseif ($leaf -match 'operator-notes') { 'operator_notes' } elseif ($isImplementation -and -not $script:AuthorityLegacyArtifactKinds) { 'implementation' } else { 'boundary' }
        # Quote an index of operative lines, never generate or infer an approval. Full originals
        # govern every dependent action; the index intentionally cannot confer authority.
        $lines = @($text -split '\r?\n' | Where-Object { $_ -match '(?i)approv|authoriz|scope|restrict|boundary|must|never|only|do not|no (?:push|merge|deploy|production)|allowed|prohibit' })
        $extract = ($lines -join ' ').Trim()
        if (-not $extract) { $extract = 'No operative line recognized. Read original before any dependent action.' }
        if ($extract.Length -gt 160) { $extract = $extract.Substring(0, 160) + ' [index clipped; original controls]' }
        # The checkpoint is the graph root and always read in full, not an inherited original.
        if ($path -ne $checkpoint) {
            $records.Add([pscustomobject][ordered]@{ path = $path; sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes)).ToLowerInvariant(); bytes = $originalBytes.Length; chars = $text.Length; kind = $kind; extract = $extract })
        }
        # An enumerated set is closed. A boundary naming a deferred artifact outside
        # that set is inconsistent, not permission to silently omit its scope.
        if ($script:AuthorityEnumeratedPaths.Count -and $path -ne $checkpoint) {
            if (-not $script:AuthorityLegacyArtifactKinds -and $kind -in @('boundary', 'approval', 'operator_notes')) {
                foreach ($candidate in @(Get-AuthorityCandidates $text $aliases)) {
                    $resolved = Resolve-AuthorityLiteral $candidate.literal $path $root $aliases
                    if ($resolved -notin $script:AuthorityArtifactPaths) { continue }
                    if ($resolved -notin $script:AuthorityEnumeratedPaths -and (Split-Path -Leaf $resolved) -notin $script:AuthorityRunRootNames) {
                        throw "AUTHORITY_ARTIFACT_UNENUMERATED: $path names required artifact $resolved; correct the source enumeration or use complete full-read fallback"
                    }
                    $script:AuthorityCheckpointFullReads += $resolved
                }
            }
            continue
        }
        # Pin the document itself. Its citations describe evidence, runtime examples and
        # other workstations. Only independent authority references add those originals.
        if ($path -ne $checkpoint -and (Test-AuthorityContextDocument $path)) { continue }
        $candidates = if ($path -eq $checkpoint) { $checkpointCandidates } else { @(Get-AuthorityCandidates $text $aliases) }
        foreach ($candidate in $candidates) {
            # Keep each waiver explicit and visible in the coordinator's digest read.
            $waiverRule = switch -Regex -CaseSensitive ($candidate.literal) {
                '[*]' { 'wildcard_star'; break }
                '[?]' { 'wildcard_question'; break }
                '^~[/\\]' { 'home_template'; break }
                '<[A-Za-z][A-Za-z0-9_-]*>' { 'angle_name'; break }
                '\{[A-Za-z_][A-Za-z0-9_-]*\}' { 'brace_name'; break }
                '(?:^|[/\\])(?:yyyy-mm-dd|yyyy/mm/dd|YYYYMMDD|yyyymmdd)(?=$|[/\\]|\.[^/\\]+$)' { 'full_date_template'; break }
                '(?<![\p{L}\p{N}\p{M}])(?:YYYY|MM|DD)(?![\p{L}\p{N}\p{M}])' { 'uppercase_date_token'; break }
            }
            if ($waiverRule) {
                $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $path; candidate = $candidate.literal; resolved = $null; reason = 'non_authority_reference'; required = $false; waiver_rule = $waiverRule })
                continue
            }
            $resolved = Resolve-AuthorityLiteral $candidate.literal $path $root $aliases
            $referenceWaiver = Get-AuthorityReferenceWaiver $text $candidate $path $checkpoint $root $resolved
            if ($referenceWaiver) {
                $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $path; candidate = $candidate.literal; resolved = $resolved; reason = 'non_authority_reference'; required = $false; waiver_rule = $referenceWaiver })
                continue
            }
            if (-not $resolved) {
                $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $path; candidate = $candidate.literal; resolved = $null; reason = 'non_authority_reference'; required = $false })
                continue
            }
            if ((Split-Path -Leaf $resolved) -in $script:AuthorityEvidenceOnlyNames) {
                $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $path; candidate = $candidate.literal; resolved = $resolved; reason = 'evidence_only'; required = $false })
                continue
            }
            $required = $true
            # A boundary's reference to an artifact carries scope even on a separate line.
            # A checkpoint locator alone is navigation; any other authority reference is a full read.
            $sourceLine = ($text.Substring(0, $candidate.index) -split '\r?\n')[-1] + ($text.Substring($candidate.index) -split '\r?\n')[0]
            # A conditional output named by a stage prompt is produced if a decision arises.
            # Current stop authority is supplied independently through the checkpoint or approvals.
            if ((Split-Path -Leaf $path) -eq 'build-stage-prompt.md' -and
                (Split-Path -Leaf $resolved) -eq 'decision-needed.md' -and
                ($text.Substring(0, $candidate.index) -split '\r?\n')[-1] -match '(?i)\bif a user decision becomes necessary, write\b[^.!?]*\bto\s+[`"'']?$') {
                $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $path; candidate = $candidate.literal; resolved = $resolved; reason = 'non_authority_reference'; required = $false; waiver_rule = 'conditional_decision_output' })
                continue
            }
            if (-not $script:AuthorityLegacyArtifactKinds -and $resolved -in $script:AuthorityArtifactPaths -and
                -not (Test-AuthorityLifecycleLocator $path $sourceLine) -and
                (($kind -in @('boundary', 'approval', 'operator_notes') -and -not $isImplementation) -or
                 ($path -eq $checkpoint -and $sourceLine -notmatch '^(?:roadmap|design|plan)_path:'))) {
                $script:AuthorityCheckpointFullReads += $resolved
            }
            if ($path -eq $checkpoint -and -not $script:AuthorityLegacyArtifactKinds) {
                $directive = ($text.Substring(0, $candidate.index) -split '\r?\n')[-1] + ($text.Substring($candidate.index) -split '\r?\n')[0]
                if ($directive -match '(?i)before\s*bootstrap.*read|read.*before\s*bootstrap|IN FULL|current.*(?:boundary|restrictions)|governing.*(?:authority|original)') { $script:AuthorityCheckpointFullReads += $resolved }
            }
            if ($script:AuthorityEnumeratedPaths.Count) {
                # Only paths explicitly required before bootstrap supplement the enumeration.
                $line = ($text.Substring(0, $candidate.index) -split '\r?\n')[-1] + ($text.Substring($candidate.index) -split '\r?\n')[0]
                $leading = ($text.Substring(0, $candidate.index) -split '\r?\n')[-1]
                $required = $resolved -in $script:AuthorityEnumeratedPaths -or $leading -match '(?i)before\s*bootstrap.*read|also.*before\s*bootstrap.*read'
                # Bounded metadata clarifications are supplementary originals. Current
                # stop restrictions remain full reads; inherited metadata uses the index.
                if ($required -and $resolved -notin $script:AuthorityEnumeratedPaths -and $line -notmatch '(?i)necessary\s*metadata\s+clarifications\s+grant\s+no\s*new\s*authority') { $script:AuthorityCheckpointFullReads += $resolved }
            }
            if (Test-Path -LiteralPath $resolved -PathType Leaf) { if ($required) { $pending.Enqueue($resolved) }; continue }
            # FS-123: in a design or plan document, a missing bare file name (no directory part) names an
            # artifact the build will create, not an original. Boundaries, approvals, the checkpoint,
            # paths with a directory and enumerated authority files stay fail-closed.
            if ($required -and $candidate.literal -notmatch '[\\/]' -and $resolved -notin $script:AuthorityEnumeratedPaths -and
                ((Split-Path -Leaf $path) -match '(?i)^(design-final|plan-draft|roadmap|build-plan|build-input)' -or
                 $path -match '(?i)[\\/]milestones[\\/]')) { $required = $false }
            $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $path; candidate = $candidate.literal; resolved = $resolved; reason = $(if ($required) { 'missing_named_original' } else { 'non_authority_reference' }); required = $required })
            if ($required) { $missing.Add($resolved) }
        }
    }
    if ($missing.Count) { throw "AUTHORITY_MISSING: $($missing -join '; ')" }
    # Enumeration is closed, so inspect references within its boundaries without expanding it.
    foreach ($record in $records) {
        if ($record.kind -ne 'implementation') { continue }
        foreach ($boundaryRecord in @($records | Where-Object kind -eq 'boundary')) {
            if (-not $script:AuthorityEnumeratedPaths.Count -and (Test-AuthorityContextDocument $boundaryRecord.path)) { continue }
            foreach ($candidate in @(Get-AuthorityCandidates ([IO.File]::ReadAllText($boundaryRecord.path)) $aliases)) {
                $boundaryText = [IO.File]::ReadAllText($boundaryRecord.path)
                $line = ($boundaryText.Substring(0, $candidate.index) -split '\r?\n')[-1] + ($boundaryText.Substring($candidate.index) -split '\r?\n')[0]
                if (Test-AuthorityLifecycleLocator $boundaryRecord.path $line) { continue }
                $resolved = Resolve-AuthorityLiteral $candidate.literal $boundaryRecord.path $root $aliases
                if ($resolved -eq $record.path) { $script:AuthorityCheckpointFullReads += $record.path }
            }
        }
    }
    return @($records | Sort-Object path)
}

function Get-AuthorityMandatoryPaths {
    param([object[]]$Records, [string]$BuildStatePath)
    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add([IO.Path]::GetFullPath($BuildStatePath))
    foreach ($record in $Records) {
        if (($script:AuthorityEnumeratedPaths.Count -eq 0 -and $record.kind -in @('approval', 'operator_notes')) -or
            $record.path -in $script:AuthorityCheckpointFullReads -or
            ($record.path -in $script:AuthorityEnumeratedPaths -and $record.path -in $script:AuthorityArtifactPaths) -or
            (Split-Path -Leaf $record.path) -in @('approvals.json', 'operator-notes.json', 'build-state.md', 'build-plan.md')) { $paths.Add($record.path) }
    }
    # The current boundary is the last boundary pointer in checkpoint order. All checkpoint
    # inline restrictions and complete approvals stay mandatory, regardless of digest size.
    $checkpointText = Get-AuthorityCheckpointText ([IO.File]::ReadAllText($BuildStatePath).TrimStart([char]0xFEFF))
    if ($script:AuthorityCurrentBoundary) {
        $paths.Add($script:AuthorityCurrentBoundary)
        return @($paths | Sort-Object -Unique)
    }
    $current = @($Records | Where-Object { $_.kind -eq 'boundary' -and $checkpointText.Contains((Split-Path -Leaf $_.path)) } | Sort-Object { $checkpointText.LastIndexOf((Split-Path -Leaf $_.path)) } | Select-Object -Last 1)
    if ($current.Count) { $paths.Add($current[0].path) }
    $newest = @($Records | Where-Object kind -eq 'boundary' | Sort-Object { (Get-Item -LiteralPath $_.path).LastWriteTimeUtc } | Select-Object -Last 1)
    if ($newest.Count) { $paths.Add($newest[0].path) }
    return @($paths | Select-Object -Unique)
}

function Get-AuthorityMarkdown {
    param([string]$RunFolder, [object[]]$Records, [string]$BuildStatePath)
    $body = Get-AuthorityMarkdownBody -RunFolder $RunFolder -Records $Records -BuildStatePath $BuildStatePath
    $mandatory = @(Get-AuthorityMandatoryPaths -Records $Records -BuildStatePath $BuildStatePath)
    # Fixed-width header keeps the measured boundary independent of warning state.
    $warningHeader = Get-AuthorityBudgetHeader -OverTarget $true
    $bootstrapChars = $body.Length + $warningHeader.Length + [IO.File]::ReadAllText($BuildStatePath).Length
    foreach ($record in $Records) { if ($record.path -in $mandatory) { $bootstrapChars += $record.chars } }
    $header = Get-AuthorityBudgetHeader -OverTarget ($bootstrapChars -gt $script:AuthorityReadBudgetChars)
    return $body.Replace("# Authority digest`n", "# Authority digest`n$header")
}

function Get-AuthorityBudgetHeader {
    param([bool]$OverTarget)
    $warning = 'WARNING: over_target; proceed with all current authority; confirm observed transcript on next resume.'
    $state = if ($OverTarget) { $warning } else { 'within_target'.PadRight($warning.Length, '.') }
    return "Budget: target $script:AuthorityReadBudgetChars chars; hard ceiling $script:AuthorityReadCeilingChars chars. $state`n"
}

function Get-AuthorityMarkdownBody {
    param([string]$RunFolder, [object[]]$Records, [string]$BuildStatePath)
    $lines = @('# Authority digest', '', 'Mechanical index only. Original records control authorization. Read each governing original IN FULL immediately before its dependent action.', '')
    $mandatory = @(Get-AuthorityMandatoryPaths -Records $Records -BuildStatePath $BuildStatePath)
    # Reserve the entire lean checkpoint ceiling, sized from its authority text only, so status,
    # cursor and rotation state changes do not alter the clipping or invalidate a digest built before resume.
    $checkpointAuthority = Get-AuthorityCheckpointText ([IO.File]::ReadAllText($BuildStatePath).TrimStart([char]0xFEFF))
    $mandatoryChars = [math]::Max(8192, $checkpointAuthority.Length)
    $prefixes = @()
    $directories = @($Records | ForEach-Object { [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($RunFolder), (Split-Path -Parent $_.path)).Replace('\', '/') } | Sort-Object -Unique)
    $files = @($Records | ForEach-Object { Split-Path -Leaf $_.path } | Sort-Object -Unique)
    $lines += 'Paths relative to run. Dk[:n]suffix = first n characters of Dk + suffix. D:F lists directory/filenames. [clipped] extracts remain in JSON.'
    $common = @($directories | Where-Object { $_ -ne '.' })
    $prefix = if ($common.Count) { $common[0] } else { '' }
    foreach ($directory in $common) { while ($prefix -and -not $directory.StartsWith($prefix + '/')) { $prefix = ($prefix -replace '/?[^/]+$', '') } }
    if ($prefix) { $lines += "P=$prefix" }
    for ($d = 0; $d -lt $directories.Count; $d++) {
        $displayDirectory = if ($prefix -and $directories[$d].StartsWith($prefix + '/')) { 'P/' + $directories[$d].Substring($prefix.Length + 1) } else { $directories[$d] }
        for ($prior = 0; $prior -lt $d; $prior++) {
            $shared = 0
            while ($shared -lt [math]::Min($directories[$prior].Length, $directories[$d].Length) -and $directories[$prior][$shared] -ceq $directories[$d][$shared]) { $shared++ }
            $compressed = "D${prior}[:$shared]" + $directories[$d].Substring($shared)
            if ($compressed.Length -lt $displayDirectory.Length) { $displayDirectory = $compressed }
        }
        $lines += "D${d}=$displayDirectory"
    }
    for ($f = 0; $f -lt $files.Count; $f++) { $lines += "F${f}=$($files[$f])" }
    $lines += ''
    if ($script:AuthorityEnumeratedPaths.Count) {
        # Structured source lists need a reversible path index, not 99 repeated
        # permission excerpts. Each D:F member maps to exactly one hashed original.
        for ($d = 0; $d -lt $directories.Count; $d++) {
            $members = @($Records | Where-Object { [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($RunFolder), (Split-Path -Parent $_.path)).Replace('\', '/') -eq $directories[$d] } | ForEach-Object { 'F' + [array]::IndexOf($files, (Split-Path -Leaf $_.path)) })
            $lines += "D${d}:" + ($members -join ',')
        }
        $lines += @('', '## Diagnostics', 'Unresolved candidates:')
        foreach ($item in $script:AuthorityDiagnostics) { $lines += "- $($item.reason)$(if ($item.PSObject.Properties['waiver_rule']) { ' [waiver: ' + $item.waiver_rule + ']' }): ``$($item.candidate)``" }
        if (-not $script:AuthorityDiagnostics.Count) { $lines += '- none' }
        return ($lines -join "`n") + "`n"
    }
    foreach ($record in $Records) {
        if ($record.path -in $mandatory) { $mandatoryChars += $record.chars }
        $directory = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($RunFolder), (Split-Path -Parent $record.path)).Replace('\', '/')
        $display = 'D' + [array]::IndexOf($directories, $directory) + '/F' + [array]::IndexOf($files, (Split-Path -Leaf $record.path))
        $prefixes += "- $display : "
    }
    # Fit only inherited navigation text mechanically, never omit a path or a mandatory
    # original. A small per-record allowance avoids another 99-source bootstrap wall.
    $overhead = (($lines -join "`n") + "`n").Length + (($prefixes -join "`n") + "`n").Length
    $diagnosticLines = @('', '## Diagnostics', 'Unresolved candidates (required originals fail closed):')
    foreach ($item in $script:AuthorityDiagnostics) { $diagnosticLines += "- $($item.reason)$(if ($item.PSObject.Properties['waiver_rule']) { ' [waiver: ' + $item.waiver_rule + ']' }): ``$($item.candidate)``" }
    if (-not $script:AuthorityDiagnostics.Count) { $diagnosticLines += '- none' }
    $overhead += (($diagnosticLines -join "`n") + "`n").Length
    $overhead += (Get-AuthorityBudgetHeader -OverTarget $true).Length
    $allowance = if ($Records.Count) { [math]::Max(0, [math]::Min(196, [math]::Floor(($script:AuthorityReadBudgetChars - $mandatoryChars - $overhead) / $Records.Count))) } else { 196 }
    for ($i = 0; $i -lt $Records.Count; $i++) {
        $extract = [string]$Records[$i].extract
        if ($extract.Length -gt $allowance) { $extract = if ($allowance -lt 10) { ''.PadRight($allowance, '~') } else { $extract.Substring(0, $allowance - 10) + ' [clipped]' } }
        $lines += $prefixes[$i] + $extract
    }
    $lines += $diagnosticLines
    return ($lines -join "`n") + "`n"
}
