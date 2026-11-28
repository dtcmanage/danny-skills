<# Reconcile owner decisions with Command Center. All writes are best effort. #>
param([string]$StateDir, [string]$CcCommand, [switch]$DryRun, [switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
$summary = [ordered]@{added=@();closed=@();skipped=$null;errors=@()}
$explicitCc = -not [string]::IsNullOrWhiteSpace($CcCommand)
if (-not $explicitCc -and $env:DT_ROUTER_CC_COMMAND) { $CcCommand = $env:DT_ROUTER_CC_COMMAND; $explicitCc = $true }
if (-not $CcCommand) {
    # cc.ps1 sits beside Skill Creation in the workspace that holds the main checkout
    # (/home/danny/Claude on the Linux session host, D:\Claude on Windows).
    $CcCommand = 'D:\Claude\_Claude-Workspace\Command Center\cc.ps1'
    try {
        $workspaceCc = Join-Path (Split-Path -Parent (Split-Path -Parent (Get-RouterMainCheckout))) 'Command Center/cc.ps1'
        if (Test-Path -LiteralPath $workspaceCc -PathType Leaf) { $CcCommand = $workspaceCc }
    } catch { }
}
function Get-ProposalValue($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Format-ProposalTime($At) {
    # Same Eastern conversion and invariant format as Format-RouterResumeAfterEt.
    $et = [TimeZoneInfo]::ConvertTime([datetimeoffset]$At, [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time'))
    return $et.ToString('yyyy-MM-dd h:mm tt', [Globalization.CultureInfo]::InvariantCulture) + ' ET'
}
function Get-FriendlyModel([string]$Model) {
    if ($Model -match '(?i)(opus|sol|luna|haiku|sonnet|fable|astra|terra)') { return [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($Matches[1].ToLowerInvariant()) }
    return 'the proposed model'
}
function Add-ProposalError([string]$Message) {
    $summary.errors += $Message
    [Console]::Error.WriteLine("Warning: proposal items: $Message")
    try {
        [IO.Directory]::CreateDirectory($StateDir) | Out-Null
        $row = @{at=([datetimeoffset]::UtcNow.ToString('o'));error=$Message} | ConvertTo-Json -Compress
        [IO.File]::AppendAllText((Join-Path $StateDir 'proposal-items.log'), "$row`n", [Text.UTF8Encoding]::new($false))
    } catch { [Console]::Error.WriteLine("Warning: proposal items log: $($_.Exception.Message)") }
}
function Invoke-ProposalCc([string[]]$Arguments) {
    # A child isolates exit/throw and LASTEXITCODE from approval and cadence callers.
    $output = @(& pwsh -NoProfile -File $CcCommand @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "CC $($Arguments[0]) failed ($LASTEXITCODE): $($output -join ' ')" }
    return ($output -join "`n")
}
function Quote-ProposalArgument([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
try {
    if (-not $StateDir) { $StateDir = Get-RouterStatePath }
    $StateDir = [IO.Path]::GetFullPath($StateDir)
    $canonical = Get-RouterStatePath -Platform Windows -StateOverride ''
    $allowed = $explicitCc -or (-not $env:DT_ROUTER_TEST_FAKE_CLI_ROOT -and $StateDir.TrimEnd('\','/') -eq $canonical.TrimEnd('\','/'))
    # DryRun always reads proposals, but never even lists CC items.
    if (-not $DryRun -and -not $allowed) { $summary.skipped = 'non-live-state' }
    elseif (-not $DryRun -and -not (Test-Path -LiteralPath $CcCommand -PathType Leaf)) { $summary.skipped = 'cc-unavailable' }
    else {
        $records = @{}
        $replaced = @{}
        $pending = @{}
        $roster = Read-RouterJsonObject (Join-Path $StateDir 'roster.json')
        $driftDeclines = @(Read-RouterJsonArray (Join-Path $StateDir 'drift-declines.json'))
        $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        foreach ($kind in @('tie','effort','roster','frontier')) {
            $store = @{tie='tie-proposals';effort='effort-proposals';roster='roster-proposals';frontier='frontier-requests'}[$kind]
            $directory = Join-Path $StateDir $store
            if (-not (Test-Path -LiteralPath $directory)) { continue }
            $files = @(Get-ChildItem -LiteralPath $directory -File -Filter $(if ($kind -eq 'roster') { 'latest.json' } else { '*.json' }))
            foreach ($file in $files) {
                # Never close items from an unreadable snapshot.
                $p = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 40
                $report = [string](Get-ProposalValue $p 'report' '')
                if ($kind -eq 'roster' -and (Get-ProposalValue $p 'proposal')) {
                    $target = [string]$p.proposal
                    # Resolve copies by filename first, never follow a copied pointer into live state.
                    $localTarget = Join-Path $directory ([IO.Path]::GetFileName($target))
                    if (-not (Test-Path -LiteralPath $localTarget)) { continue }
                    $file = Get-Item -LiteralPath $localTarget
                    $p = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 40
                }
                $job = [string](Get-ProposalValue $p 'job' $(if ($kind -eq 'frontier') { Get-ProposalValue $p 'category' 'router' } else { 'router' }))
                $tier = [string](Get-ProposalValue $p 'tier' 'standard')
                $status = [string](Get-ProposalValue $p 'status' '')
                $at = Get-ProposalValue $p 'generated_at' (Get-ProposalValue $p 'created_at' $file.LastWriteTimeUtc)
                if (-not $report) { $report = [string](Get-ProposalValue $p 'report' '') }
                if (-not $report -and $kind -eq 'tie') { $report = Join-Path $StateDir ('bench/runs/' + [string](Get-ProposalValue $p 'run_id' '') + '/report.md') }
                $instance = Get-ProposalValue $p 'run_id'
                if (-not $instance -and $kind -eq 'frontier') { $instance = Get-ProposalValue $p 'id' }
                if (-not $instance -and $kind -eq 'effort' -and $report) { $instance = Split-Path -Leaf (Split-Path -Parent ($report.Replace('\','/'))) }
                if (-not $instance) { $instance = Get-ProposalValue $p 'pass_id' (Get-ProposalValue $p 'generated_at' (Get-ProposalValue $p 'created_at')) }
                if (-not $instance) {
                    # Atomic decision writers replace file creation times. Hash immutable content instead.
                    $basis = $p | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
                    foreach ($name in @($basis.PSObject.Properties.Name)) {
                        if ($name -eq 'status' -or $name -match '^(decided|approved|declined|revoked|superseded|used)_at$' -or $name -eq 'note') { $basis.PSObject.Properties.Remove($name) }
                    }
                    $instance = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($basis | ConvertTo-Json -Compress -Depth 40)))).ToLowerInvariant()
                }
                $instance = [uri]::EscapeDataString([string]$instance)
                $key = "router-proposal/$kind/$($file.BaseName)/$instance"
                $isPending = $status -ceq 'pending'
                if ($kind -eq 'roster') {
                    $changes = @(Get-ProposalValue $p 'changes' @())
                    $isPending = (Get-ProposalValue $p 'approved') -eq $false -and @(Get-ProposalValue $p 'validation_errors' @()).Count -eq 0
                    $status = if (Get-ProposalValue $p 'approved' $false) { 'approved' } else { '' }
                    if ($isPending -and $roster) {
                        # Approval writes roster.json, not the source proposal. Keep partial approvals open.
                        $remaining = @($changes | Where-Object {
                            $entry = Get-ProposalValue (Get-ProposalValue $roster 'jobs') $_.job
                            $category = Get-ProposalValue $_ 'category'
                            $slots = if ($category) { Get-RouterEffectiveSlots -Entry $entry -Category $category } else { $entry }
                            (Get-ProposalValue $slots $_.slot) -cne $_.to
                        })
                        $approvedAt = Get-ProposalValue $roster 'approved_at'
                        if ($approvedAt -and [datetimeoffset]$approvedAt -ge [datetimeoffset]$at -and (($changes.Count -gt 0 -and $remaining.Count -eq 0) -or ($changes.Count -eq 0 -and (Get-ProposalValue $roster 'generated_at') -eq (Get-ProposalValue $p 'generated_at')))) {
                            $isPending = $false; $status = if (Get-ProposalValue $roster 'approved' $false) { 'approved' } else { 'revoked' }
                            $at = $approvedAt
                        }
                    }
                    if ($isPending -and $changes.Count) {
                        $unsettled = @($changes | Where-Object {
                            $change = $_
                            -not @($driftDeclines | Where-Object { $_.job -ceq $change.job -and [datetimeoffset]$_.declined_at -ge [datetimeoffset]$at }).Count
                        })
                        if (-not $unsettled.Count) {
                            $isPending = $false; $status = 'declined'
                            $at = @($driftDeclines | Sort-Object { [datetimeoffset]$_.declined_at })[-1].declined_at
                        }
                    }
                }
                $decisionAt = $file.LastWriteTimeUtc
                foreach ($field in @('decided_at',"${status}_at")) { if (Get-ProposalValue $p $field) { $decisionAt = Get-ProposalValue $p $field; break } }
                if ($kind -eq 'roster' -and $status -in @('approved','revoked','declined')) { $decisionAt = $at }
                $note = if ($status -in @('approved','declined','revoked','superseded','used')) { [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($status) + ' ' + (Format-ProposalTime $decisionAt) + '.' } else { 'No longer pending.' }
                $records[$key] = $note
                $replaced["router-proposal/$kind/$($file.BaseName)/"] = 'Superseded ' + (Format-ProposalTime $file.LastWriteTimeUtc) + '.'
                if (-not $isPending) { continue }
                $suffix = " -Job $(Quote-ProposalArgument $job) -Difficulty $tier"
                $description = ''
                switch ($kind) {
                    tie {
                        $models = @($p.configurations.PSObject.Properties | ForEach-Object { Get-FriendlyModel $_.Value.model }) -join '/'
                        $title = "Approve or decline the $job $models tie"
                        $description = "The comparison found no meaningful difference between $models for $job."
                        $approve = '-ApproveTie' + $suffix; $decline = '-DeclineTie' + $suffix
                    }
                    effort {
                        $raising = @{low=0;medium=1;high=2;xhigh=3}[[string]$p.proposed_effort] -gt @{low=0;medium=1;high=2;xhigh=3}[[string]$p.current_effort]
                        $direction = if ($raising) { 'raising' } else { 'lowering' }
                        $title = "Approve or decline $direction $job effort from $($p.current_effort) to $($p.proposed_effort)"
                        $description = "The comparison supports $direction $(Get-FriendlyModel $p.model) effort for $job."
                        $approve = '-ApproveEffort' + $suffix; $decline = '-DeclineEffort' + $suffix
                    }
                    roster {
                        $title = "Approve or decline the router's proposed model changes"
                        $description = "The router recommends changing its model choices for $(@($changes | ForEach-Object job | Sort-Object -Unique) -join ', ')."
                        $approve = '-Approve'
                        # There is no general roster-decline action; drift decisions are job-specific.
                        $decline = @($changes | ForEach-Object job | Sort-Object -Unique | ForEach-Object { '-DeclineDrift -Job ' + (Quote-ProposalArgument $_) })
                    }
                    frontier {
                        $title = "Approve or decline a frontier model request for $job"
                        $description = "Earlier attempts could not finish this work; the review requests $(Get-FriendlyModel (Get-ProposalValue $p 'proposed_model' '')) for $job."
                        $approve = '-ApproveFrontier -RequestId ' + (Quote-ProposalArgument $p.id) + ' -Model ' + (Quote-ProposalArgument (Get-ProposalValue $p 'proposed_model' ''))
                        $decline = '-DeclineFrontier -RequestId ' + (Quote-ProposalArgument $p.id)
                    }
                }
                $quality = Get-ProposalValue $p 'quality_evidence'
                $evidenceText = @()
                $verdict = Get-ProposalValue $quality 'verdict' (Get-ProposalValue $p 'verdict')
                $plainVerdict = @{candidate_better='the proposed choice performed better';incumbent_better='the current choice performed better';no_difference='neither choice performed meaningfully better';inconclusive='the results were inconclusive'}
                if ($verdict -and $plainVerdict.ContainsKey([string]$verdict)) { $evidenceText += "the reviewers found that $($plainVerdict[[string]$verdict])" }
                foreach ($lane in @('incumbent','candidate','effort_up','effort_down')) {
                    $score = Get-ProposalValue $p $lane
                    if ($null -ne (Get-ProposalValue $score 'passed')) {
                        $label = @{incumbent='current choice';candidate='proposed choice';effort_up='higher effort';effort_down='lower effort'}[$lane]
                        $evidenceText += "$label passed $($score.passed) tasks"
                    }
                }
                if ($evidenceText.Count) { $description += ' Results: ' + ($evidenceText -join '; ') + '.' }
                $context = "$description Proposed $(Format-ProposalTime $at). Your decision is needed before the router can use this change."
                $baseCommand = 'pwsh -NoProfile -File scripts/model-router/approve-roster.ps1 '
                $details = if ($report) { "Report: $report`n`n" } else { '' }
                $details += "Approve:`ncd `"$repo`"`n$baseCommand$approve`n`nDecline:`n"
                if ($kind -eq 'roster') { $details += "The CLI has no general roster decline; these commands keep current choices after drift alerts.`n" }
                foreach ($command in @($decline)) { $details += "cd `"$repo`"`n$baseCommand$command`n" }
                $starter = "Skill Creation: review the pending model-router $kind proposal for $job ($tier) in $($file.FullName); read its bench report, summarize the evidence in plain language with one recommendation, then apply Danny's decision with approve-roster.ps1 and confirm the live roster."
                $pending[$key] = @{key=$key;title=($title -replace '[\r\n]+',' ');context=$context;details=$details;starter=$starter}
            }
        }
        if ($DryRun) { $summary.added = @($pending.Values | Sort-Object key); $summary.skipped = 'dry-run' }
        else {
            $open = @(Invoke-ProposalCc -Arguments @('list') | ConvertFrom-Json -Depth 40)
            $openKeys = @($open | ForEach-Object { Get-ProposalValue $_ 'thread_key' })
            foreach ($item in @($pending.Values | Sort-Object key)) {
                if ($item.key -in $openKeys) { continue }
                try {
                    $null = Invoke-ProposalCc -Arguments @('add','--title',$item.title,'--workstation','Skill Creation','--kind','needs-you','--area','build','--context',$item.context,'--next-action','Say approve or decline.','--details',$item.details,'--starter-prompt',$item.starter,'--thread-key',$item.key)
                    $summary.added += $item.key
                } catch { Add-ProposalError $_.Exception.Message }
            }
            foreach ($item in $open) {
                $key = [string](Get-ProposalValue $item 'thread_key' '')
                if (-not $key.StartsWith('router-proposal/') -or $pending.ContainsKey($key)) { continue }
                $note = if ($records.ContainsKey($key)) { $records[$key] } else { 'No longer pending.' }
                if (-not $records.ContainsKey($key)) {
                    foreach ($prefix in $replaced.Keys) { if ($key.StartsWith($prefix)) { $note = $replaced[$prefix]; break } }
                }
                try {
                    $null = Invoke-ProposalCc -Arguments @('done',"id:$($item.id)",'--done-note',$note)
                    $summary.closed += @{id=$item.id;key=$key;note=$note}
                } catch { Add-ProposalError $_.Exception.Message }
            }
        }
    }
} catch { Add-ProposalError $_.Exception.Message }
if ($Json) { ConvertTo-Json -InputObject $summary -Depth 12 -Compress }
# Do not exit here: hooks invoke this script in process and preserve their own exit status.
