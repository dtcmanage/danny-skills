[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StatePath,

    [Parameter(Mandatory)]
    [ValidateRange(1, 99)]
    [int]$Round,

    [Parameter(Mandatory)]
    [string]$DispositionsPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Atomic([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + '.tmp.' + $PID)
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-OptionalString([object]$Object, [string]$Name) {
    if ($Object.PSObject.Properties[$Name]) { return [string]$Object.$Name }
    return ''
}

function Assert-DispositionHistory([object[]]$Entries) {
    $allowed = @('ACCEPT', 'REJECT', 'DEFER', 'COUNTER')
    $adjudicationDisposition = @{ A = 'ACCEPT'; B = 'REJECT'; C = 'DEFER' }

    foreach ($historyEntry in @($Entries | Sort-Object { [int]$_.round })) {
        $reRaised = if ($historyEntry.PSObject.Properties['re_raised_rejections']) {
            @($historyEntry.re_raised_rejections | ForEach-Object { [string]$_ })
        }
        else { @() }

        foreach ($finding in @($historyEntry.findings)) {
            $id = [string]$finding.id
            $disposition = Get-OptionalString -Object $finding -Name 'disposition'
            $note = Get-OptionalString -Object $finding -Name 'note'
            if ($allowed -notcontains $disposition -or [string]::IsNullOrWhiteSpace($note)) {
                throw "Round $($historyEntry.round) finding '$id' does not have a complete recorded disposition."
            }
            if ([bool]$finding.ambiguous_root_cause -and
                [string]::IsNullOrWhiteSpace((Get-OptionalString -Object $finding -Name 'ambiguity_resolution'))) {
                throw "Round $($historyEntry.round) finding '$id' requires ambiguity_resolution."
            }
            if ($reRaised -contains $id) {
                $choice = Get-OptionalString -Object $finding -Name 'user_adjudication'
                if ($choice -notin @('A', 'B', 'C')) {
                    throw "Round $($historyEntry.round) re-raised finding '$id' requires user_adjudication A, B, or C."
                }
                if ($disposition -ne $adjudicationDisposition[$choice]) {
                    throw "Round $($historyEntry.round) finding '$id' adjudication $choice conflicts with disposition $disposition."
                }
            }
        }

        if ([bool]$historyEntry.adjudication_required -and -not [bool]$historyEntry.adjudication_resolved) {
            throw "Round $($historyEntry.round) requires unresolved user adjudication."
        }
    }
}

foreach ($required in @($StatePath, $DispositionsPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required state input not found: $required"
    }
}

try {
    $entries = @(Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
}
catch {
    throw "Review state is not valid JSON: $StatePath. $($_.Exception.Message)"
}
if ($entries.Count -eq 0) {
    throw "Review state is empty: $StatePath"
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'validate-review-semantics.ps1')
Assert-DtReviewSemanticHistory -Entries $entries

$orderedEntries = @($entries | Sort-Object { [int]$_.round })
$latestRound = [int]$orderedEntries[-1].round
if ($Round -ne $latestRound) {
    throw "Round $Round cannot record dispositions because the latest review state round is $latestRound. Retroactive disposition writes are refused."
}
$entry = $orderedEntries[-1]

# Before accepting a candidate receipt, prove that all review artifacts and all
# earlier disposition receipts still match state. The current round is allowed
# to be the sole receipt-free disposition entry until this call commits it.
Assert-DtReviewStructuredReceipts -Entries $orderedEntries
$priorEntries = @($orderedEntries | Where-Object { [int]$_.round -lt $Round })
Assert-DtReviewDispositionReceipts -Entries $priorEntries

$dispositionsRaw = Get-Content -LiteralPath $DispositionsPath -Raw
$dispositionsHash = (Get-FileHash -LiteralPath $DispositionsPath -Algorithm SHA256).Hash.ToUpperInvariant()
try {
    $dispositions = @($dispositionsRaw | ConvertFrom-Json)
}
catch {
    throw "Dispositions JSON is malformed: $DispositionsPath. $($_.Exception.Message)"
}

$allowed = @('ACCEPT', 'REJECT', 'DEFER', 'COUNTER')
$adjudicationDisposition = @{ A = 'ACCEPT'; B = 'REJECT'; C = 'DEFER' }
$byId = @{}
foreach ($item in $dispositions) {
    $id = [string]$item.id
    if ([string]::IsNullOrWhiteSpace($id) -or $byId.ContainsKey($id)) {
        throw "Disposition IDs must be non-empty and unique; invalid ID '$id'."
    }
    if ($allowed -notcontains [string]$item.disposition) {
        throw "Finding '$id' has invalid disposition '$($item.disposition)'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.note)) {
        throw "Finding '$id' requires a concise evidence-based disposition note."
    }
    $byId[$id] = $item
}

$findingIds = @($entry.findings | ForEach-Object { [string]$_.id })
$missing = @($findingIds | Where-Object { -not $byId.ContainsKey($_) })
$extra = @($byId.Keys | Where-Object { $findingIds -notcontains $_ })
if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
    throw "Disposition coverage mismatch. Missing: $($missing -join ', '); extra: $($extra -join ', ')."
}

# A byte-identical replay is the only legal second call. Return before touching
# any state object or rewriting the file so recovery cannot alter timestamps.
if ($entry.PSObject.Properties['dispositions_sha256']) {
    $recordedHash = [string]$entry.dispositions_sha256
    if ([string]::IsNullOrWhiteSpace($recordedHash)) {
        throw "Round $Round contains an invalid empty disposition receipt. Explicit state repair is required."
    }
    if ($recordedHash -cne $dispositionsHash) {
        throw "Round $Round dispositions are immutable and the supplied artifact differs from the recorded receipt."
    }
    Assert-DtReviewStateReceipts -Entries $orderedEntries
    Assert-DispositionHistory -Entries $orderedEntries
    [pscustomobject]@{
        status = 'already_recorded'
        round = $Round
        findings_recorded = @($entry.findings).Count
        adjudication_resolved = [bool]$entry.adjudication_resolved
        state_path = (Resolve-Path -LiteralPath $StatePath).Path
    } | ConvertTo-Json -Compress
    return
}

$populatedFields = foreach ($finding in @($entry.findings)) {
    foreach ($name in @('disposition', 'note', 'ambiguity_resolution', 'user_adjudication')) {
        if (-not [string]::IsNullOrWhiteSpace((Get-OptionalString -Object $finding -Name $name))) {
            "$($finding.id).$name"
        }
    }
}
$partialReceiptFields = @('dispositions_path', 'dispositions_recorded_at_utc') |
    Where-Object { $entry.PSObject.Properties[$_] }
if (@($populatedFields).Count -gt 0 -or @($partialReceiptFields).Count -gt 0 -or [bool]$entry.adjudication_resolved) {
    throw "Round $Round already contains disposition state without an immutable receipt. Refusing overwrite; explicit state repair is required."
}

foreach ($finding in @($entry.findings)) {
    $item = $byId[[string]$finding.id]
    if ($entry.adjudication_required -and $entry.re_raised_rejections -contains $finding.id) {
        if (-not $item.PSObject.Properties['user_adjudication'] -or [string]$item.user_adjudication -notin @('A', 'B', 'C')) {
            throw "Re-raised rejected finding '$($finding.id)' requires user_adjudication A, B, or C."
        }
        $expectedDisposition = $adjudicationDisposition[[string]$item.user_adjudication]
        if ([string]$item.disposition -ne $expectedDisposition) {
            throw "Finding '$($finding.id)' adjudication $($item.user_adjudication) requires disposition $expectedDisposition, not $($item.disposition)."
        }
        $finding.user_adjudication = [string]$item.user_adjudication
    }
    $finding.disposition = [string]$item.disposition
    $finding.note = [string]$item.note
    if ($item.PSObject.Properties['ambiguity_resolution']) {
        $finding.ambiguity_resolution = [string]$item.ambiguity_resolution
    }
    if ($finding.ambiguous_root_cause -and [string]::IsNullOrWhiteSpace([string]$finding.ambiguity_resolution)) {
        throw "Finding '$($finding.id)' is AMBIGUOUS_ROOT_CAUSE and requires ambiguity_resolution before advancement."
    }
}

if ($entry.adjudication_required) {
    $entry.adjudication_resolved = $true
}
$entry | Add-Member -NotePropertyName dispositions_path -NotePropertyValue (Resolve-Path -LiteralPath $DispositionsPath).Path
$entry | Add-Member -NotePropertyName dispositions_sha256 -NotePropertyValue $dispositionsHash
$entry | Add-Member -NotePropertyName dispositions_recorded_at_utc -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o')

# Re-run both review-lifecycle and disposition semantics over the complete
# candidate history. Nothing is persisted unless every round remains valid.
Assert-DtReviewSemanticHistory -Entries $orderedEntries
Assert-DispositionHistory -Entries $orderedEntries
Assert-DtReviewStateReceipts -Entries $orderedEntries

$json = ConvertTo-Json -InputObject $orderedEntries -Depth 10
Write-Atomic -Path $StatePath -Content ($json + "`n")

[pscustomobject]@{
    status = 'ok'
    round = $Round
    findings_recorded = $findingIds.Count
    adjudication_resolved = [bool]$entry.adjudication_resolved
    state_path = (Resolve-Path -LiteralPath $StatePath).Path
} | ConvertTo-Json -Compress
