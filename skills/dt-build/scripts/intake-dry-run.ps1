param(
    [Parameter(Mandatory)]
    [string]$RepoPath,

    [Parameter(Mandatory)]
    [string]$RoadmapPath,

    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [string]$RunId = "phase7a-dryrun",
    [string]$IntegrationBranch = "",
    [switch]$UseExistingIntegrationBranch,
    [string]$MergeTarget = "main",
    [string]$ResumeRunId = "",
    [string]$DeterministicTimestampUtc = "2026-01-01T00:00:00Z",
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

function Expand-Template {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][hashtable]$Replacements
    )
    $raw = Get-Content -LiteralPath $TemplatePath -Raw
    foreach ($key in $Replacements.Keys) {
        $raw = $raw.Replace($key, [string]$Replacements[$key])
    }
    return $raw
}

$repoRoot = Resolve-SkillRepoRoot
$skillRoot = Join-Path $repoRoot "skills\dt-build"
$roadmapValidatorPath = Join-Path $repoRoot "skills\dt-roadmap\scripts\roadmap-validator.ps1"
$schemaPath = Join-Path $repoRoot "skills\dt-roadmap\references\roadmap-schema.md"
$targetRepo = if (Test-Path -LiteralPath $RepoPath -PathType Container) { (Resolve-Path -LiteralPath $RepoPath).Path } else { "" }

if ([string]::IsNullOrWhiteSpace($targetRepo)) {
    throw "INTAKE_FAIL: repo not found: $RepoPath"
}
$gitRoot = (& git -C $targetRepo rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "INTAKE_FAIL: target is not a git repo: $targetRepo`n$($gitRoot -join "`n")"
}
$targetRepo = ([string]($gitRoot | Select-Object -Last 1)).Trim()
if ([string]::IsNullOrWhiteSpace($IntegrationBranch)) {
    $IntegrationBranch = "build/$RunId"
}
foreach ($ref in @($IntegrationBranch, $MergeTarget)) {
    & git -C $targetRepo check-ref-format --branch $ref *> $null
    if ($LASTEXITCODE -ne 0) { throw "INTAKE_FAIL: invalid branch name: $ref" }
}
if ($IntegrationBranch -eq $MergeTarget) {
    throw "INTAKE_FAIL: integration branch must differ from protected merge target '$MergeTarget'."
}
& git -C $targetRepo show-ref --verify --quiet "refs/heads/$MergeTarget"
if ($LASTEXITCODE -ne 0) {
    throw "INTAKE_FAIL: merge target branch not found: $MergeTarget"
}
& git -C $targetRepo show-ref --verify --quiet "refs/heads/$IntegrationBranch"
$integrationExists = ($LASTEXITCODE -eq 0)
if ($UseExistingIntegrationBranch -and -not $integrationExists) {
    throw "INTAKE_FAIL: requested existing integration branch not found: $IntegrationBranch"
}
if (-not $UseExistingIntegrationBranch -and $integrationExists -and [string]::IsNullOrWhiteSpace($ResumeRunId)) {
    throw "INTAKE_FAIL: integration branch already exists; use -UseExistingIntegrationBranch or provide a resume RUN_ID: $IntegrationBranch"
}
if (-not [string]::IsNullOrWhiteSpace($ResumeRunId) -and -not $integrationExists) {
    throw "INTAKE_FAIL: resume requires the existing integration branch state carrier: $IntegrationBranch"
}

if (-not (Test-Path -LiteralPath $RoadmapPath)) {
    throw "INTAKE_FAIL: roadmap not found: $RoadmapPath"
}
if (-not (Test-Path -LiteralPath $roadmapValidatorPath)) {
    throw "INTAKE_FAIL: roadmap validator not found: $roadmapValidatorPath"
}
if (-not (Test-Path -LiteralPath $schemaPath)) {
    throw "INTAKE_FAIL: roadmap schema not found: $schemaPath"
}

if (-not [string]::IsNullOrWhiteSpace($ResumeRunId)) {
    $resumePath = Join-Path (Join-Path $targetRepo ".dt-build") $ResumeRunId
    if (Test-Path -LiteralPath $resumePath) {
        $legacyBuildPlan = Join-Path $resumePath "build-plan.md"
        $isLegacy = $true
        if (Test-Path -LiteralPath $legacyBuildPlan) {
            $bp = Get-Content -LiteralPath $legacyBuildPlan -Raw
            if ($bp -match "(?m)^intake_contract:\s*roadmap-v1\s*$") {
                $isLegacy = $false
            }
        }

        if ($isLegacy) {
            throw ("INTAKE_HARD_CUTOVER_REJECT: run folder '$resumePath' is pre-refactor and cannot be resumed. " +
                "Per Contract Freeze Gate decision (design-final.md), legacy .dt-build runs are historical-only with no migration path.")
        }
    }
}

$validatorJson = & pwsh -NoProfile -File $roadmapValidatorPath -RoadmapPath $RoadmapPath -SchemaPath $schemaPath -Json 2>&1
$validatorExitCode = $LASTEXITCODE
if ($validatorExitCode -ne 0) {
    throw ($validatorJson -join "`n")
}
$validation = ($validatorJson -join "`n") | ConvertFrom-Json

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$baseRef = if ($UseExistingIntegrationBranch -or $integrationExists) { $IntegrationBranch } else { $MergeTarget }
$baseSha = (& git -C $targetRepo rev-parse $baseRef).Trim()
$runDir = Join-Path $OutputDirectory $RunId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$stateTemplate = Join-Path $skillRoot "assets\build-state.md.template"
$decisionTemplate = Join-Path $skillRoot "assets\build-decision-log.md.template"
$planTemplate = Join-Path $skillRoot "assets\build-plan.md.template"

$repl = @{
    "__RUN_ID__" = $RunId
    "__BASE_SHA__" = $baseSha
    "__INTEGRATION_BRANCH__" = $IntegrationBranch
    "__MERGE_TARGET__" = $MergeTarget
    "__ROADMAP_PATH__" = (Resolve-Path -LiteralPath $RoadmapPath).Path
    "__SCHEMA_MAJOR__" = [string]$validation.schema_version_major
    "__MILESTONE_COUNT__" = [string]$validation.milestone_count
    "__CHUNK_COUNT__" = [string]$validation.chunk_count
    "__VERIFICATION_COUNT__" = [string]$validation.verification_item_count
    "__GENERATED_AT_UTC__" = $DeterministicTimestampUtc
}

$stateContent = Expand-Template -TemplatePath $stateTemplate -Replacements $repl
$decisionContent = Expand-Template -TemplatePath $decisionTemplate -Replacements $repl
$planContent = Expand-Template -TemplatePath $planTemplate -Replacements $repl

$writeStateScript = Join-Path $skillRoot "scripts\write-build-state.ps1"
& $writeStateScript -Path (Join-Path $runDir "build-state.md") -Content $stateContent | Out-Null
& $writeStateScript -Path (Join-Path $runDir "build-decision-log.md") -Content $decisionContent | Out-Null
& $writeStateScript -Path (Join-Path $runDir "build-plan.md") -Content $planContent | Out-Null

$contractsPath = Join-Path $repoRoot "references\canonical-dimension-contract.md"
$glossaryPath = Join-Path $repoRoot "references\glossary-contract.md"
$buildReferencePackScript = Join-Path $skillRoot "scripts\build-reference-pack.ps1"
$manifestJson = & $buildReferencePackScript -RunDirectory $runDir -ContractsSourcePath $contractsPath -GlossarySourcePath $glossaryPath -Json
$manifestObj = $manifestJson | ConvertFrom-Json

$spawnPreflightScript = Join-Path $skillRoot "scripts\spawn-preflight.ps1"
$spawnJson = & $spawnPreflightScript -ManifestPath $manifestObj.manifest_path -RequiredEntitlements @("contracts", "glossary") -Json
$spawnObj = $spawnJson | ConvertFrom-Json

$result = [pscustomobject]@{
    pass = $true
    roadmap_path = (Resolve-Path -LiteralPath $RoadmapPath).Path
    output_run_directory = (Resolve-Path -LiteralPath $runDir).Path
    schema_major = $validation.schema_version_major
    milestone_count = $validation.milestone_count
    chunk_count = $validation.chunk_count
    verification_item_count = $validation.verification_item_count
    spawn_preflight = $spawnObj.pass
    files = @(
        "build-state.md",
        "build-decision-log.md",
        "build-plan.md",
        "reference-pack-contracts.md",
        "reference-pack-glossary.md",
        "reference-manifest.md"
    )
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else {
    Write-Output ("PASS: intake dry-run wrote {0} files to {1}" -f $result.files.Count, $result.output_run_directory)
}
