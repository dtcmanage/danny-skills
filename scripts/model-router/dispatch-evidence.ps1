# Per-output dispatch evidence shared by the public command and lane adapters.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../security/redact-secrets.ps1')
. (Join-Path $PSScriptRoot 'router-common.ps1')

function Get-DispatchValue {
    param([object]$Record, [string]$Name)
    if ($Record -is [Collections.IDictionary]) { if ($Record.Contains($Name)) { return $Record[$Name] }; return $null }
    if ($null -ne $Record -and $Record.PSObject.Properties[$Name]) { return $Record.$Name }
    return $null
}

function Get-RouterNamedModel {
    # The ladder is the roster's model vocabulary, not a second selection policy.
    param([string]$Model)
    $name = $Model.Trim().ToLowerInvariant() -replace '\s*\[\d+[km]\]$', ''
    $name = $name -replace '-\d{8}$', ''
    $map = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/ladders.json') -Raw | ConvertFrom-Json
    foreach ($lane in $map.lanes.PSObject.Properties) {
        foreach ($entry in $lane.Value.ladder) {
            $canonical = [string]$entry.model
            $base = $canonical -replace '-\d{8}$', ''
            $family = if ($base -match '^claude-([a-z]+)-') { $Matches[1] } else { $base -replace '^gpt-[\d.]+-', '' }
            if ($name -in @($base, $family)) {
                $selectedName = if ($lane.Name -eq 'claude' -and $name -match '^claude-(opus|sonnet|haiku)-\d+(-\d+)*(-\d{8})?$') { $Model.Trim() } else { $canonical }
                return [pscustomobject]@{model=$selectedName; vendor=$lane.Name; frontier=[bool]$entry.frontier}
            }
        }
    }
    # Older selectable catalog entries remain valid run pins. Unknown names and
    # frontier descriptions still require explicit approval.
    try {
        $catalog = Get-CodexModelCatalog
        $currentMajor = @($map.lanes.codex.ladder | ForEach-Object { if ($_.model -match '^gpt-(\d+)') { [int]$Matches[1] } } | Measure-Object -Maximum).Maximum
        foreach ($entry in $catalog.models) {
            if ($entry.slug -ceq $name -and $name -match '^gpt-(\d+)(?:\.\d+)?(?:-[a-z]+)?$' -and
                [int]$Matches[1] -le $currentMajor -and $entry.visibility -eq 'list' -and
                (Get-DispatchValue $entry 'description') -notmatch 'frontier' -and
                $name -notmatch '(astra|fable|spark)' -and -not (Get-DispatchValue $entry 'upgrade')) {
                return [pscustomobject]@{model=$name;vendor='codex';frontier=$false}
            }
        }
    } catch { } # An unavailable catalog supplies no additional known names.
    if ($name -match '^claude-(opus|sonnet|haiku)-\d+(-\d+)*(-\d{8})?$') {
        return [pscustomobject]@{model=$Model.Trim();vendor='claude';frontier=$false}
    }
    return $null
}

function Assert-RouterNamedModel {
    param([string]$Model, [object]$Resolution, [string]$RequestId)
    if (-not $RequestId) { $RequestId = Get-DispatchValue $Resolution 'frontier_request' }
    $named = if ($Model) { Get-RouterNamedModel $Model } else { $null }
    if ($Model -and (-not $named -or $named.frontier) -and -not $RequestId) { throw 'FRONTIER_REQUEST_REQUIRED' }
    if (-not $RequestId) { return }
    $request = Read-RouterFrontierRequest $RequestId
    if ($Model -and (-not $named -or $named.model -cne $request.proposed_model)) { throw 'FRONTIER_REQUEST_MODEL_MISMATCH' }
    if (Get-DispatchValue $request 'launched_dispatch_id') { throw 'FRONTIER_REQUEST_USED' }
    if ($request.status -eq 'used' -and -not (Get-DispatchValue $request 'reserved_at')) { throw 'FRONTIER_REQUEST_USED' }
    if ($request.status -in @('approved','used')) {
        $decided = [datetimeoffset]::MinValue
        if ((Get-DispatchValue $request 'approved_model') -cne $request.proposed_model -or
            -not [datetimeoffset]::TryParse([string](Get-DispatchValue $request 'decided_at'),[ref]$decided)) { throw 'FRONTIER_REQUEST_APPROVAL_INVALID' }
    }
}

function Assert-RouterDispatchPick {
    param([object]$Resolution, [string]$Model, [string]$RequestId, [switch]$CallerResolution)
    $finalModel = if ($Model) { $Model } else { Get-DispatchValue $Resolution 'model' }
    $named = if ($finalModel) { Get-RouterNamedModel $finalModel } else { $null }
    if ($CallerResolution) { Assert-RouterNamedModel -Model $finalModel -Resolution $Resolution -RequestId $RequestId }
    # Approved roster names outside the ladder (such as gpt-image-2) stay valid.
    # Unknown explicit overrides are refused by Assert-RouterNamedModel.
    if ($named -and $named.frontier) {
        Assert-RouterNamedModel -Model $finalModel -Resolution $Resolution -RequestId $RequestId
        return $true
    }
    return $false
}

function Exit-RouterFrontierFailure {
    param([object]$FailureRecord)
    $pickVariable = Get-Variable -Name routerPick -ErrorAction SilentlyContinue
    if ($pickVariable) { Undo-RouterFrontierReservation -Resolution $pickVariable.Value }
    throw $FailureRecord
}

function Assert-RouterTestCliPath {
    param([string]$Path)
    if (-not $env:DT_ROUTER_TEST_FAKE_CLI_ROOT) { return }
    try {
        # Resolve links on every ancestor as well as the executable itself.
        $resolvePhysical = {
            param([string]$Value)
            $item = Get-Item -LiteralPath $Value -Force -ErrorAction Stop
            if ($item.LinkType) { return $item.ResolveLinkTarget($true).FullName }
            $parent = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
            if (-not $parent) { return $item.FullName }
            Join-Path (& $resolvePhysical $parent.FullName) $item.Name
        }
        $root = (& $resolvePhysical $env:DT_ROUTER_TEST_FAKE_CLI_ROOT).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        $resolved = & $resolvePhysical $Path
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not $resolved.StartsWith($root,$comparison)) { throw 'CLI outside fixture root' }
    } catch { throw 'ROUTER_TEST_FAKE_CLI_REQUIRED: resolved CLI is outside DT_ROUTER_TEST_FAKE_CLI_ROOT or cannot be resolved' }
}

function Add-RouterPreflightOutcome {
    param([string]$DispatchId,[string]$Repo,[string]$Tier,[string]$Lane,[string]$Model,[string]$Category,[int]$Attempt,[object]$FailureCategory,[object]$Diagnosis)
    Add-RouterOutcomeBestEffort -Row ([pscustomobject]@{key=($DispatchId + ':preflight');run_id='preflight';repo=$Repo;tier=$Tier;escalated=$false;at=[datetimeoffset]::UtcNow.ToString('o');source='canary';lane=$Lane;model=$Model;category=$Category;attempt=$Attempt;pass=$false;failure_category=$FailureCategory;diagnosis=$Diagnosis})
}

function Get-RouterReservedFrontierPick {
    # A resolver reservation may be handed to a wrapper once, with its request id.
    param([string]$RequestId,[string]$Category,[string]$Lane,[bool]$Protected)
    $request = Read-RouterFrontierRequest $RequestId
    if ($request.status -ne 'used') { return $null }
    Assert-RouterNamedModel -Model $request.proposed_model -RequestId $RequestId
    if ($request.category -cne $Category) { throw 'FRONTIER_REQUEST_CATEGORY_MISMATCH' }
    $vendor = (Get-RouterNamedModel $request.proposed_model).vendor
    if ($Lane -and $Lane -ne $vendor) { throw 'FRONTIER_REQUEST_LANE_MISMATCH' }
    [pscustomobject]@{status='ok';model=$request.proposed_model;effort='high';category=$Category;job=(Get-RouterCategoryJob $Category);lane=$vendor;vendor=$vendor;protected=$Protected;difficulty='hard';reason="Approved frontier request $RequestId; one dispatch only.";frontier_request=$RequestId;table_source=$null;table_date=$null;alerts=@()}
}

function Start-RouterFrontierDispatch {
    param([object]$Resolution,[string]$DispatchId)
    $id = Get-DispatchValue $Resolution 'frontier_request'
    if (-not $id) { return $false }
    Use-RouterOutcomeMutex -StateDir (Get-RouterStateDir) -Action {
        Assert-RouterNamedModel -Model $Resolution.model -RequestId $id
        $request = Read-RouterFrontierRequest $id
        if ($request.status -ne 'used') { throw 'FRONTIER_REQUEST_APPROVAL_INVALID' }
        $request | Add-Member -Force -NotePropertyName launched_dispatch_id -NotePropertyValue $DispatchId
        Write-RouterJsonAtomic (Get-RouterFrontierRequestPath $id) $request
    }
    return $true
}

function Undo-RouterFrontierReservation {
    param([object]$Resolution,[string]$DispatchId)
    $id = Get-DispatchValue $Resolution 'frontier_request'
    if (-not $id) { return }
    try {
        Use-RouterOutcomeMutex -StateDir (Get-RouterStateDir) -Action {
            $request = Read-RouterFrontierRequest $id
            $launched = Get-DispatchValue $request 'launched_dispatch_id'
            if ($launched -and $launched -cne $DispatchId) { return }
            if ($request.status -eq 'used') {
                $request.status = 'approved'
                $request.PSObject.Properties.Remove('used_at')
                $request.PSObject.Properties.Remove('reserved_at')
                $request.PSObject.Properties.Remove('launched_dispatch_id')
                Write-RouterJsonAtomic (Get-RouterFrontierRequestPath $id) $request
            }
        }
    } catch { Write-Warning "Frontier reservation release failed: $($_.Exception.Message)" }
}

function Read-RouterCodexExecutionEvidence {
    # Plain exec output is kept intact. Correlate only a CLI-reported session ID
    # with its own rollout, never the newest file or the requested model.
    param([string]$Stream, [string]$Project, [datetime]$StartedAt = (Get-Date))
    $result = [pscustomobject]@{model=$null;usage=$null;rollout_path=$null}
    $idMatch = [regex]::Match($Stream, '(?im)^session id:\s*([0-9a-f]{8}-[0-9a-f-]{27,})\s*$')
    if (-not $idMatch.Success) { return $result }
    $id = $idMatch.Groups[1].Value
    $sessionRoot = if ($env:DT_MODEL_ROUTER_CODEX_SESSIONS) { $env:DT_MODEL_ROUTER_CODEX_SESSIONS } elseif ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'sessions' } else { Join-Path $HOME '.codex/sessions' }
    if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) { return $result }
    # UTC/local day and the previous day cover a launch across midnight. Flat
    # fixture/legacy roots are checked directly without recursive enumeration.
    # Codex session ids are UUIDv7: their creation date identifies the rollout
    # directory even when this is a historical stream. UUIDv4 fixtures use launch time.
    $compactId = $id.Replace('-','')
    if ($compactId.Length -eq 32 -and $compactId[12] -eq '7') {
        try { $StartedAt = [datetimeoffset]::FromUnixTimeMilliseconds([Convert]::ToInt64($compactId.Substring(0,12),16)).UtcDateTime } catch { return $result }
    }
    $days = @($StartedAt, $StartedAt.ToUniversalTime(), $StartedAt.AddDays(-1), $StartedAt.AddDays(1)) | ForEach-Object { $_.ToString('yyyy/MM/dd') } | Select-Object -Unique
    try {
        $files = @(Get-ChildItem -LiteralPath $sessionRoot -File -Filter "rollout-*-$id.jsonl")
        foreach ($day in $days) {
            $folder = Join-Path $sessionRoot $day
            if (Test-Path -LiteralPath $folder) { $files += @(Get-ChildItem -LiteralPath $folder -File -Filter "rollout-*-$id.jsonl") }
        }
    } catch { return $result }
    if ($files.Count -ne 1) { return $result }
    $matched = $false; $model = $null; $usage = $null
    try {
    foreach ($line in [IO.File]::ReadLines($files[0].FullName)) {
        try { $event = $line | ConvertFrom-Json -Depth 40 -DateKind String } catch { continue }
        $payload = Get-DispatchValue $event 'payload'
        switch (Get-DispatchValue $event 'type') {
            'session_meta' {
                $cwd = Get-DispatchValue $payload 'cwd'
                $matched = (Get-DispatchValue $payload 'id') -ceq $id -and $cwd -and [IO.Path]::GetFullPath($cwd) -ieq [IO.Path]::GetFullPath($Project)
                if (-not $matched) { return $result }
            }
            'turn_context' { $model = Get-DispatchValue $payload 'model' }
            'event_msg' {
                if ((Get-DispatchValue $payload 'type') -eq 'token_count') { $usage = Get-DispatchValue (Get-DispatchValue $payload 'info') 'total_token_usage' }
            }
        }
    }
    } catch { return $result } # Telemetry never changes a successful execution.
    if ($matched) { $result.model=$model; $result.usage=$usage; $result.rollout_path=$files[0].FullName }
    return $result
}

function New-RouterDispatchContext {
    param([object]$Context, [string]$Project, [string]$Category, [int]$Attempt = 1,
          [string]$LogicalTaskId, [string]$PriorDispatchId, [string]$RequestedModel,
          [string]$OverrideReason, [string]$PromptPath, [switch]$AdHoc, [switch]$Preflight)
    if ($Context) { return $Context }
    if (-not $LogicalTaskId -and -not $AdHoc -and $PromptPath -and (Test-Path -LiteralPath $PromptPath -PathType Leaf)) {
        $promptText = [IO.File]::ReadAllText($PromptPath)
        $run = [regex]::Match($promptText, '(?m)^RUN_ID:\s*([^\r\n]+)')
        $chunk = [regex]::Match($promptText, '(?m)^chunk_id:\s*([^\r\n]+)')
        if ($run.Success -and $chunk.Success) { $LogicalTaskId = $run.Groups[1].Value.Trim() + ':' + $chunk.Groups[1].Value.Trim() }
    }
    if (-not $LogicalTaskId) {
        $identityPath = [IO.Path]::GetFullPath($(if ($PromptPath) { $PromptPath } else { $Project })).ToLowerInvariant()
        $LogicalTaskId = 'adhoc:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identityPath))).ToLowerInvariant()
    }
    [pscustomobject]@{
        dispatch_id = [guid]::NewGuid().ToString('N')
        logical_task_id = $LogicalTaskId
        preflight = [bool]$Preflight
        attempt = $Attempt; prior_dispatch_id = if ($PriorDispatchId) { $PriorDispatchId } else { $null }
        category = $Category; host = [Environment]::MachineName; project = [IO.Path]::GetFullPath($Project)
        requested_model = if ($RequestedModel) { $RequestedModel } else { $null }
        override_reason = if ($OverrideReason) { Invoke-SecretRedaction -Text $OverrideReason } else { $null }
        fallback_reason = $null; started_utc = [datetimeoffset]::UtcNow.ToString('o')
    }
}

function Write-RouterDispatchEvidence {
    param([string]$Path, [object]$Record, [object]$Context,
          [ValidateSet('started','finished','wait')][string]$Phase = 'finished',
          [object]$ExitCode, [object]$ActualModel, [object]$Usage)
    foreach ($name in @('dispatch_id','logical_task_id','attempt','prior_dispatch_id','category','host','project','requested_model','override_reason','fallback_reason','started_utc')) {
        $Record | Add-Member -Force -NotePropertyName $name -NotePropertyValue (Get-DispatchValue $Context $name)
    }
    foreach ($name in @('resolved_model','effort','difficulty','failure_category')) {
        if (-not $Record.PSObject.Properties[$name]) { $Record | Add-Member -NotePropertyName $name -NotePropertyValue $null }
    }
    $finished = if ($Phase -eq 'finished') { [datetimeoffset]::UtcNow.ToString('o') } else { $null }
    $fields = @{
        actual_model = $ActualModel; usage = $Usage; independent_acceptance = (Get-DispatchValue $Record 'independent_acceptance')
        finished_utc = $finished
        duration_ms = if ($finished) { [long](([datetimeoffset]$finished - [datetimeoffset]$Context.started_utc).TotalMilliseconds) } else { $null }
        execution_result = if ($null -ne $ExitCode) { if ($ExitCode -eq 0) { 'success' } else { 'failure' } } else { $null }
    }
    foreach ($name in $fields.Keys) { $Record | Add-Member -Force -NotePropertyName $name -NotePropertyValue $fields[$name] }
    foreach ($name in @('selection_reason','override_reason','termination_reason','disclosure_line')) {
        $value = Get-DispatchValue $Record $name
        if ($value) { $Record.$name = Invoke-SecretRedaction -Text ([string]$value) }
    }
    try {
        Write-RouterEvidenceJson -Path $Path -Record $Record
        $sidecar = $null
        try { $sidecar = Select-RouterDispatchEvidence -Candidate (Read-RouterDispatchEvidence -Path ($Path + '.finished.json')) } catch { }
        if (-not (Get-DispatchValue $Context 'preflight') -and (Get-DispatchValue $sidecar 'dispatch_id') -cne (Get-DispatchValue $Context 'dispatch_id')) { Sync-RouterDispatchOutcome -ProvenancePath $Path }
    } catch {
        if ($Phase -ne 'finished') { throw }
        $failure = $_.Exception.Message
        try {
            if (-not (Get-DispatchValue $Context 'preflight')) { Write-RouterPendingOutcome -ProvenancePath $Path -Record $Record }
        } catch { $failure += '; pending pointer: ' + $_.Exception.Message }
        [Console]::Error.WriteLine("ROUTER_OUTCOME_INDEX_FAILED: $failure")
    }
}

function Write-RouterEvidenceJson {
    param([string]$Path, [object]$Record)
    [IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($Path)))) | Out-Null
    # An unreadable sidecar is not superseded evidence that we may remove.
    $sidecarReadFailed = $false
    if (Test-Path -LiteralPath ($Path + '.finished.json')) {
        try { $null = Read-RouterDispatchEvidence -Path $Path -SidecarReadFailed ([ref]$sidecarReadFailed) } catch { }
    }
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Record | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        $watch = [Diagnostics.Stopwatch]::StartNew()
        for ($retry = 0; ; $retry++) {
            try { [IO.File]::Move($temp, $Path, $true); break }
            catch {
                if ($watch.ElapsedMilliseconds -ge 10000 -or $_.Exception.ToString() -notmatch '(?i)access.*denied|being used|sharing violation') {
                    if (-not (Get-DispatchValue $Record 'finished_utc')) { throw }
                    # The original file can still be held. Keep the finished bytes
                    # beside it; all evidence readers understand this sidecar.
                    [IO.File]::Move($temp, ($Path + '.finished.json'), $true)
                    if (-not (Get-DispatchValue $Record 'preflight')) { Write-RouterPendingOutcome -ProvenancePath $Path -Record $Record }
                    return
                }
                Start-Sleep -Milliseconds $(if ($retry -lt 3) { 50 } else { 200 })
            }
        }
        if (-not $sidecarReadFailed) { Remove-Item -LiteralPath ($Path + '.finished.json') -Force -ErrorAction SilentlyContinue }
    }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function Select-RouterDispatchEvidence {
    # Compare state instants, never file timestamps or timestamp strings. A
    # finished snapshot outranks a started target; identities must agree.
    param([object]$Record, [object]$Candidate)
    if (-not $Candidate) { return $Record }
    if ($Record -and (Get-DispatchValue $Record 'dispatch_id') -cne (Get-DispatchValue $Candidate 'dispatch_id')) { return $Record }
    $candidateFinished = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string](Get-DispatchValue $Candidate 'finished_utc'), [ref]$candidateFinished)) { return $Record }
    $recordFinished = [datetimeoffset]::MinValue
    if (-not $Record -or -not [datetimeoffset]::TryParse([string](Get-DispatchValue $Record 'finished_utc'), [ref]$recordFinished)) { return $Candidate }
    $candidateAccepted = [datetimeoffset]::MinValue; $recordAccepted = [datetimeoffset]::MinValue
    [void][datetimeoffset]::TryParse([string](Get-DispatchValue $Candidate 'accepted_at_utc'), [ref]$candidateAccepted)
    [void][datetimeoffset]::TryParse([string](Get-DispatchValue $Record 'accepted_at_utc'), [ref]$recordAccepted)
    $candidateInstant = if ($candidateAccepted -gt $candidateFinished) { $candidateAccepted } else { $candidateFinished }
    $recordInstant = if ($recordAccepted -gt $recordFinished) { $recordAccepted } else { $recordFinished }
    if ($candidateInstant -gt $recordInstant) { return $Candidate }
    return $Record
}

function Read-RouterDispatchEvidence {
    param([string]$Path, [ref]$SidecarReadFailed)
    if ($SidecarReadFailed) { $SidecarReadFailed.Value = $false }
    $record = $null; $readFailure = $null
    try { $record = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -Depth 40 -DateKind String } catch { $readFailure = $_ }
    if (Test-Path -LiteralPath ($Path + '.finished.json')) {
        try { $finished = [IO.File]::ReadAllText($Path + '.finished.json') | ConvertFrom-Json -Depth 40 -DateKind String }
        catch {
            if ($SidecarReadFailed) { $SidecarReadFailed.Value = $true }
            if (-not $readFailure) { return $record }
            throw
        }
        $chosen = Select-RouterDispatchEvidence -Record $record -Candidate $finished
        if ($chosen) { return $chosen }
    }
    if ($readFailure) { throw $readFailure }
    return $record
}

function Set-RouterDispatchAcceptance {
    # Only the deterministic acceptance producers call this, never a worker exit.
    param([string]$ProvenancePath, [string]$DispatchId, [bool]$Accepted)
    if (-not $DispatchId -or -not $ProvenancePath) { throw 'DISPATCH_ACCEPTANCE_ID_REQUIRED' }
    Use-RouterOutcomeMutex -StateDir (Get-RouterStateDir) -Action {
        $row = Read-RouterDispatchEvidence -Path $ProvenancePath
        if ((Get-DispatchValue $row 'dispatch_id') -cne $DispatchId) { throw 'DISPATCH_ACCEPTANCE_ID_MISMATCH' }
        if (-not (Get-DispatchValue $row 'finished_utc')) { throw 'DISPATCH_ACCEPTANCE_NOT_FINISHED' }
        $row | Add-Member -Force -NotePropertyName independent_acceptance -NotePropertyValue $Accepted
        $row | Add-Member -Force -NotePropertyName accepted_at_utc -NotePropertyValue ([datetimeoffset]::UtcNow.ToString('o'))
        Write-RouterEvidenceJson -Path $ProvenancePath -Record $row
    }
    Sync-RouterDispatchOutcome -ProvenancePath $ProvenancePath
}

function ConvertTo-DispatchOutcome {
    param([object]$Item, [string]$ProvenancePath)
    $row = [ordered]@{
        key=('dispatch:' + $Item.dispatch_id); source=$(if ((Get-DispatchValue $Item 'source') -eq 'bench') { 'bench' } else { 'dispatch' })
        repo=(Split-Path -Leaf $Item.project); run_id=$Item.logical_task_id; at=$Item.started_utc
        lane=(Get-DispatchValue $Item 'lane'); model=(Get-DispatchValue $Item 'actual_model')
        tier=(Get-DispatchValue $Item 'tier'); escalated=[bool](Get-DispatchValue $Item 'escalated_from'); diagnosis=(Get-DispatchValue $Item 'diagnosis'); provenance_path=$ProvenancePath
    }
    foreach ($field in @('dispatch_id','logical_task_id','attempt','prior_dispatch_id','category','job','host','project','requested_model','resolved_model','actual_model','effort','difficulty','override_reason','fallback_reason','fallback_refusal','started_utc','finished_utc','duration_ms','execution_result','failure_category','usage','independent_acceptance','accepted_at_utc')) { $row[$field] = Get-DispatchValue $Item $field }
    $workstation = Get-DispatchValue $Item 'workstation'
    if (-not $workstation -and $Item.project -match '[/\\]_Claude-Workspace[/\\]([^/\\]+)') { $workstation = $Matches[1] }
    if ($workstation) { $row.workstation = $workstation }
    $row.pass = $row.independent_acceptance
    return [pscustomobject]$row
}

function Read-RouterOutcomeLedger {
    param([string]$Path)
    $records = [ordered]@{}
    $raw = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $Path) {
        foreach ($match in [regex]::Matches([IO.File]::ReadAllText($Path), '[^\r\n]*(?:\r\n|\n|\r|$)')) {
            if (-not $match.Value.Length) { continue }
            $key = $null; $snapshot = $null; $row = $null
            try {
                $row = $match.Value | ConvertFrom-Json -Depth 40 -DateKind String
                $key = Get-DispatchValue $row 'key'
                if ($key) { $records[[string]$key] = $row; $snapshot = $row | ConvertTo-Json -Depth 40 -Compress }
            } catch { $key = $null } # Preserve unparseable legacy evidence verbatim too.
            $raw.Add([pscustomobject]@{key=$key; text=$match.Value; snapshot=$snapshot; row=$row})
        }
    }
    [pscustomobject]@{records=$records; raw=$raw}
}

function Write-RouterOutcomeLedger {
    param([string]$Path, [object]$Ledger, [System.Collections.IDictionary]$Records)
    $text = [Text.StringBuilder]::new()
    $seen = @{}
    foreach ($line in $Ledger.raw) {
        if (-not $line.key) { [void]$text.Append($line.text); continue }
        if (-not $Records.Contains($line.key)) { continue }
        $snapshot = $Records[$line.key] | ConvertTo-Json -Depth 40 -Compress
        if ($snapshot -ceq $line.snapshot) { [void]$text.Append($line.text) }
        else { [void]$text.Append($snapshot + "`n") }
        $seen[$line.key] = $true
    }
    foreach ($key in $Records.Keys) {
        if ($seen.ContainsKey($key)) { continue }
        if ($text.Length -and $text[$text.Length-1] -ne "`n") { [void]$text.Append("`n") }
        [void]$text.Append(($Records[$key] | ConvertTo-Json -Depth 40 -Compress) + "`n")
    }
    $content = $text.ToString()
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -ceq $content) { return }
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try { [IO.File]::WriteAllText($temp,$content,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$Path,$true) }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function Get-RouterPendingOutcomes {
    param([string]$StateDir)
    $folder = Join-Path $StateDir 'outcome-pending'
    if (Test-Path -LiteralPath $folder -PathType Container) { Get-ChildItem -LiteralPath $folder -Filter '*.txt' -File }
}

function Write-RouterPendingOutcome {
    param([string]$ProvenancePath,[object]$Record,[switch]$OutcomeRow)
    $state = Get-RouterStateDir
    $folder = Join-Path $state 'outcome-pending'
    [void][IO.Directory]::CreateDirectory($folder)
    $identity = if ($OutcomeRow) { Get-DispatchValue $Record 'key' } else { Get-DispatchValue $Record 'dispatch_id' }
    if (-not $identity) { throw 'ROUTER_PENDING_ID_REQUIRED' }
    $name = if ($OutcomeRow) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))) } else { $identity }
    $pointer = [pscustomobject]@{provenance_path=$ProvenancePath; snapshot=$Record; kind=$(if ($OutcomeRow) {'outcome'} else {'dispatch'})}
    $path = Join-Path $folder ($name + '.txt')
    $temp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($pointer | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp,$path,$true)
    } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function Merge-RouterDispatchOutcome {
    param([System.Collections.IDictionary]$Rows,[object]$Row)
    if ($Rows.Contains($Row.key)) {
        $prior = $Rows[$Row.key]
        if ((Get-DispatchValue $prior 'finished_utc') -and -not (Get-DispatchValue $Row 'finished_utc')) { return }
        if ((Get-DispatchValue $Row 'dispatch_id') -and $null -ne (Get-DispatchValue $prior 'independent_acceptance') -and $null -eq $Row.independent_acceptance) { $Row.independent_acceptance = $prior.independent_acceptance; $Row.pass = $prior.independent_acceptance }
        if ($prior.PSObject.Properties['retry_count']) { $Row | Add-Member -Force -NotePropertyName retry_count -NotePropertyValue $prior.retry_count }
    }
    $Rows[$Row.key] = $Row
}

function Read-RouterPendingOutcome {
    param([IO.FileInfo]$Pointer)
    # Also understand path-only pointers written before snapshots existed.
    $text = [IO.File]::ReadAllText($Pointer.FullName).Trim()
    $pointerRecord = $null
    if ($text.StartsWith('{')) { $pointerRecord = $text | ConvertFrom-Json -Depth 40 -DateKind String }
    $source = if ($pointerRecord) { Get-DispatchValue $pointerRecord 'provenance_path' } else { $text }
    $snapshot = Get-DispatchValue $pointerRecord 'snapshot'
    $kind = Get-DispatchValue $pointerRecord 'kind'
    $item = $null; $reason = 'missing target'
    if ($source) {
        try {
            $item = Read-RouterDispatchEvidence -Path $source
            if (-not (Get-DispatchValue $item 'dispatch_id') -or -not (Get-DispatchValue $item 'logical_task_id') -or -not (Get-DispatchValue $item 'project') -or -not (Get-DispatchValue $item 'started_utc')) { throw 'malformed dispatch target' }
            if ((Get-DispatchValue $snapshot 'dispatch_id') -and $item.dispatch_id -cne $snapshot.dispatch_id) { throw 'dispatch target replaced by a different dispatch' }
        } catch { $item = $null; $reason = $_.Exception.Message }
    }
    $fromSnapshot = $false
    $chosen = Select-RouterDispatchEvidence -Record $item -Candidate $snapshot
    if (-not $item -or [object]::ReferenceEquals($chosen, $snapshot)) {
        $usable = if ($kind -eq 'outcome') { (Get-DispatchValue $snapshot 'key') -and (Get-DispatchValue $snapshot 'source') } else {
            (Get-DispatchValue $snapshot 'dispatch_id') -and (Get-DispatchValue $snapshot 'logical_task_id') -and (Get-DispatchValue $snapshot 'project') -and (Get-DispatchValue $snapshot 'started_utc')
        }
        if (-not $usable) { throw "ROUTER_PENDING_UNRESOLVED: $reason; no usable snapshot" }
        $item = $snapshot; $fromSnapshot = $true
    }
    if ($null -ne (Get-DispatchValue $snapshot 'independent_acceptance') -and $null -eq (Get-DispatchValue $item 'independent_acceptance')) {
        throw 'ROUTER_PENDING_UNRESOLVED: chosen record lacks snapshot acceptance verdict'
    }
    if (Get-DispatchValue $item 'preflight') { return $null }
    $row = if ($kind -eq 'outcome') { $item } else { ConvertTo-DispatchOutcome $item $source }
    if ($fromSnapshot) { $row | Add-Member -Force -NotePropertyName evidence_source -NotePropertyValue 'snapshot' }
    return $row
}

function Import-RouterPendingOutcomes {
    # Per-pointer guards; remove successful pointers only AFTER ledger commit.
    param([string]$StateDir,[object[]]$Pending,[System.Collections.IDictionary]$Rows,[hashtable]$ArchivedKeys = @{})
    foreach ($pointer in $Pending) {
        try {
            $row = Read-RouterPendingOutcome -Pointer $pointer
            if ($row -and -not $ArchivedKeys.ContainsKey($row.key)) { Merge-RouterDispatchOutcome -Rows $Rows -Row $row }
            $pointer
        } catch {
            $reason = (Invoke-SecretRedaction -Text $_.Exception.Message) -replace '[\r\n]+',' '
            try {
                $folder = Join-Path $StateDir 'outcome-pending/unresolved'
                [void][IO.Directory]::CreateDirectory($folder)
                $destination = Join-Path $folder $pointer.Name
                [IO.File]::WriteAllText(($destination + '.reason.json'), (@{reason=$reason} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
                [IO.File]::Move($pointer.FullName,$destination,$true)
            } catch { $reason += '; quarantine failed: ' + $_.Exception.Message }
            [Console]::Error.WriteLine("ROUTER_PENDING_UNRESOLVED: $($pointer.Name): $reason")
        }
    }
}

function Sync-RouterDispatchOutcome {
    param([Parameter(Mandatory)][string]$ProvenancePath)
    $state = Get-RouterStatePath
    try {
        $state = Get-RouterStateDir
        Use-RouterOutcomeMutex -StateDir $state -TimeoutMs 5000 -Action {
            $pending = @(Get-RouterPendingOutcomes -StateDir $state)
            $path = Join-Path $state 'outcomes.jsonl'
            $ledger = Read-RouterOutcomeLedger $path
            $rows = $ledger.records
            $drained = @(Import-RouterPendingOutcomes -StateDir $state -Pending $pending -Rows $rows)
            $item = Read-RouterDispatchEvidence -Path $ProvenancePath
            if (-not (Get-DispatchValue $item 'preflight')) {
                $row = ConvertTo-DispatchOutcome $item ([IO.Path]::GetFullPath($ProvenancePath))
                Merge-RouterDispatchOutcome -Rows $rows -Row $row
            }
            Write-RouterOutcomeLedger $path $ledger $rows
            foreach ($pointer in $drained) { Remove-Item -LiteralPath $pointer.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        $failure = $_.Exception.Message
        try {
            $item = Read-RouterDispatchEvidence -Path $ProvenancePath
            Write-RouterPendingOutcome -ProvenancePath $ProvenancePath -Record $item
        } catch { $failure += '; pending pointer: ' + $_.Exception.Message }
        [Console]::Error.WriteLine("ROUTER_OUTCOME_INDEX_FAILED: $failure")
    }
}

function Add-RouterOutcomeBestEffort {
    param([object]$Row)
    try { Add-RouterOutcome -Row $Row }
    catch {
        $failure = $_.Exception.Message
        try { Write-RouterPendingOutcome -Record $Row -OutcomeRow } catch { $failure += '; pending pointer: ' + $_.Exception.Message }
        [Console]::Error.WriteLine("ROUTER_OUTCOME_INDEX_FAILED: $failure")
    }
}
