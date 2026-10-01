Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
$script:passed = 0
function Assert-True([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
function Read-Seed { Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30 }
function Invoke-Approval { param([string[]]$Options) & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') @Options 2>&1 }
$priorState = $env:DT_MODEL_ROUTER_STATE
$priorTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$priorSessions = $env:DT_MODEL_ROUTER_CODEX_SESSIONS
$temp = Join-Path $env:TEMP ('roster-approval-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $temp 'sessions'
[IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_CODEX_SESSIONS) | Out-Null
$stub = Join-Path $temp 'transport.ps1'
Set-Content -LiteralPath $stub -Value 'param($request) return [pscustomobject]@{id="stub"}'
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $stub
$catalog = [pscustomobject]@{models=@([pscustomobject]@{slug='gpt-6.1-sol';visibility='list'},[pscustomobject]@{slug='gpt-6-luna';visibility='list'})}
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
try {
    $show = @(Invoke-Approval -Options @('-Show')) -join "`n"
    Assert-True ($show -match 'No roster proposal' -and $show -match 'Current roster') 'show without proposal'
    $null = Invoke-Approval -Options @('-Seed')
    $latest = Get-Content -LiteralPath (Join-Path $temp 'roster-proposals/latest.json') -Raw | ConvertFrom-Json
    $show = @(Invoke-Approval -Options @('-Show')) -join "`n"
    Assert-True ((Test-Path -LiteralPath $latest.proposal) -and $show -match '\| Job \| Current \| Proposed' -and $show -match 'Current roster') 'seed writes proposal and show prints report'
    $seed = Get-Content -Raw -LiteralPath $latest.proposal | ConvertFrom-Json -Depth 30
    foreach ($job in @(Get-RouterJobs)) {
        $want = Get-RouterJobEffort -Job $job
        Assert-True ($seed.jobs.$job.first_effort -ceq $want -and $seed.jobs.$job.backup_effort -ceq $want) "seed fixed effort $job"
        if ($want) { Assert-True ($show -match "$job.*effort $want.*effort $want") "show both efforts $job" }
    }
    Assert-True ($show -match 'first_effort' -and $show -match 'backup_effort' -and $null -eq $seed.jobs.illustrator.first_effort -and $null -eq $seed.jobs.illustrator.backup_effort) 'show effort columns and illustrator null'
    $before = Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog
    Assert-True ($before.roster_source -eq 'default') 'seed alone uses default roster'
    $null = Invoke-Approval -Options @('-Approve')
    $approved = Get-Content -LiteralPath (Join-Path $temp 'roster.json') -Raw | ConvertFrom-Json
    $next = Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog
    Assert-True ($approved.approved -eq $true -and $approved.approved_at -and $next.roster_source -eq 'state') 'approve writes roster and next resolver call uses state'
    $null = Invoke-Approval -Options @('-Revoke')
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'roster.json')) 'revoke preserves roster file'
    $revoked = Get-Content -LiteralPath (Join-Path $temp 'roster.json') -Raw | ConvertFrom-Json
    Assert-True ($revoked.approved -eq $false -and (Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog).roster_source -eq 'default') 'revoke clears approval and resolver uses default roster'
    $proposal = Read-Seed
    $proposal.jobs.fast.backup = 'claude-sonnet-5'
    $proposal.jobs.writer.backup = 'gpt-5.6-sol'
    $proposal | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $latest.proposal
    $output = @(Invoke-Approval -Options @('-Approve')) -join "`n"
    Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'ROSTER_MODEL_CAP' -and (Get-Content -LiteralPath (Join-Path $temp 'roster.json') -Raw | ConvertFrom-Json).approved -eq $false) 'over-cap proposal refused with error'
    $output = @(Invoke-Approval -Options @('-Approve','-Jobs','writer')) -join "`n"
    Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'ROSTER_MODEL_CAP') 'subset that exceeds cap refused with named error'
    $null = Invoke-Approval -Options @('-Approve','-Jobs','fast')
    $subset = Get-Content -LiteralPath (Join-Path $temp 'roster.json') -Raw | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $subset.approved -and $subset.jobs.fast.backup -eq 'claude-sonnet-5' -and $subset.jobs.writer.backup -eq 'gpt-6.1-sol') 'subset within cap approves only selected job'
    $output = @(Invoke-Approval -Options @('-Approve','-Jobs','fast,writer')) -join "`n"
    Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'ROSTER_MODEL_CAP' -and $output -notmatch 'Unknown roster job') 'comma separated Jobs via File evaluates both selected jobs against cap'
    $proposal = Read-Seed
    $proposal.jobs.coder.first = 'unknown-model'
    $proposal | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $latest.proposal
    $output = @(Invoke-Approval -Options @('-Approve')) -join "`n"
    Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'ROSTER_MODEL_VENDOR: coder/first') 'invalid non-cap proposal names model error'
    $proposal = Read-Seed
    $proposal | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $latest.proposal
    $null = Invoke-Approval -Options @('-Approve')
    @([pscustomobject]@{model='gpt-6.1-sol';job='coder';marked_at='2026-09-28T00:00:00Z'}) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $temp 'drift-marks.json')
    Assert-True ((Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog).model -eq 'claude-opus-5-5') 'drift mark uses backup'
    $null = Invoke-Approval -Options @('-DeclineDrift','-Job','coder')
    Assert-True ((@(Read-RouterJsonArray -Path (Join-Path $temp 'drift-marks.json')).Count -eq 0) -and (Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog).model -eq 'gpt-6.1-sol') 'decline drift removes mark and restores first choice'
    $declines = @(Read-RouterJsonArray -Path (Join-Path $temp 'drift-declines.json'))
    Assert-True ($declines.Count -eq 1 -and $declines[0].model -eq 'gpt-6.1-sol' -and $declines[0].job -eq 'coder' -and $declines[0].declined_at) 'decline persists model and job'
    @([pscustomobject]@{model='gpt-6.1-sol';job='coder';marked_at='2026-09-28T00:00:00Z'},[pscustomobject]@{model='gpt-6-luna';job='fast';marked_at='2026-09-28T00:00:00Z'}) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $temp 'drift-marks.json')
    $proposal = Read-Seed
    $proposal.jobs.coder.first = 'claude-opus-5-5'; $proposal.jobs.coder.first_vendor = 'claude'
    $proposal.jobs.coder.backup = 'gpt-6.1-sol'; $proposal.jobs.coder.backup_vendor = 'codex'
    $proposal | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $latest.proposal
    $null = Invoke-Approval -Options @('-Approve')
    $marks = @(Read-RouterJsonArray -Path (Join-Path $temp 'drift-marks.json'))
    Assert-True ($marks.Count -eq 1 -and $marks[0].job -eq 'fast') 'approval clears marks only for changed first choice'
    Assert-True (@(Read-RouterJsonArray -Path (Join-Path $temp 'drift-declines.json')).Count -eq 0) 'approval clears decline when first choice changes'
    foreach ($options in @(@('-Show','-Job','coder'),@('-Show','-Jobs','coder'))) {
        $output = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') @options 2>&1) -join "`n"
        Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'require') "ignored switch rejected: $($options -join ' ')"
    }
    Write-Output "PASS: $script:passed tests"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
