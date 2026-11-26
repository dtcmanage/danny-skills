Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0; $failed = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failed.Add($Message) }
}
. (Join-Path $PSScriptRoot '../dependency-analysis.ps1')
$raw = Get-Content (Join-Path $PSScriptRoot 'fixtures/v23-dependencies.md') -Raw
$surfaces = Read-MilestoneSurfaces $raw
$milestones = @(
    [pscustomobject]@{ id = 'M01'; dependencies = '-' },
    [pscustomobject]@{ id = 'M02'; dependencies = 'M01' },
    [pscustomobject]@{ id = 'M03'; dependencies = 'M01' }
)
$result = Get-MilestoneDependencyAnalysis $milestones $surfaces
Check ($result.warnings.Count -eq 2 -and ($result.warnings -join ' ') -match 'DEPENDENCY_UNJUSTIFIED.*no shared write surface or consumed interface') 'v23 false web prerequisites flagged with reasons'
Check (($result.errors -join ' ') -match 'DEPENDENCY_OVERLAP_UNDECLARED.*target_lock.py') 'v23 hidden per-slot lock overlap caught'
Check (($result.errors -join ' ') -match 'DEPENDENCY_CONSUMPTION_UNDECLARED.*config:slot_lock') 'missing provider dependency caught'
Check ($result.dependencies.M02.Count -eq 0 -and ($result.dependencies.M03 -join ',') -eq 'M02') 'computed graph releases host work and serializes lock integration'
$milestones[1].dependencies = '-'; $milestones[2].dependencies = 'M02'
$clean = Get-MilestoneDependencyAnalysis $milestones $surfaces
Check ($clean.errors.Count -eq 0 -and $clean.warnings.Count -eq 0) 'clean corrected fixture'
$reordered = Get-MilestoneDependencyAnalysis @($milestones[2], $milestones[0], $milestones[1]) @($surfaces[2], $surfaces[1], $surfaces[0])
Check (($reordered.edges | ConvertTo-Json -Compress) -ceq ($clean.edges | ConvertTo-Json -Compress)) 'row order cannot create dependencies'
foreach ($case in @(
    @('.env.example', '.env.example', $true),
    @('.env.example', 'README.md', $false),
    @('.env.example', '**/.env.*', $true),
    @('config/.env.example', '.env.example', $false),
    @('a', '?', $true),
    @('a', 'b', $false),
    @('deploy/**', 'deploy/target_lock.py', $true),
    @('deploy/*.py', 'deploy/target_*.py', $true),
    @('src/**/config?.ts', 'src/config1.*', $true),
    @('src/*.ts', 'src/nested/file.ts', $false),
    @('web/**', 'host/**', $false),
    @('src/a*.ts', 'src/b*.ts', $false),
    @('src/A.ts', 'src/a.ts', $false)
)) { Check ((Test-GlobIntersection $case[0] $case[1]) -eq $case[2]) "glob intersection $($case[0]) <> $($case[1])" }
$reverse = @([pscustomobject]@{id='M01';dependencies='M02'}, [pscustomobject]@{id='M02';dependencies='-'})
$rootSurfaces = Read-MilestoneSurfaces @'
## Milestone Surfaces
| milestone-id | write-surface | provides | consumes | design-source |
| --- | --- | --- | --- | --- |
| M01 | .env.example | - | - | root config |
| M02 | **/.env.* | - | - | config templates |
'@
$rootMilestones = @([pscustomobject]@{id='M01';dependencies='-'}, [pscustomobject]@{id='M02';dependencies='-'})
$rootOverlap = Get-MilestoneDependencyAnalysis $rootMilestones $rootSurfaces
Check (($rootOverlap.errors -join ' ') -match 'DEPENDENCY_OVERLAP_UNDECLARED' -and ($rootOverlap.dependencies.M02 -join ',') -eq 'M01') 'root surface overlap requires serialization'
$rootSurfaces[1].'write-surface' = 'README.md'
$rootSeparate = Get-MilestoneDependencyAnalysis $rootMilestones $rootSurfaces
Check ($rootSeparate.errors.Count -eq 0 -and $rootSeparate.edges.Count -eq 0 -and $rootSeparate.dependencies.M02.Count -eq 0) 'distinct root surfaces stay independent'
$reverseSurfaces = @(
    [pscustomobject]@{'milestone-id'='M01';'write-surface'='shared/**';provides='-';consumes='api:slots';'design-source'='consumer'},
    [pscustomobject]@{'milestone-id'='M02';'write-surface'='shared/slots.py';provides='api:slots';consumes='-';'design-source'='provider'}
)
$r = Get-MilestoneDependencyAnalysis $reverse $reverseSurfaces
Check ($r.errors.Count -eq 0 -and ($r.dependencies.M01 -join ',') -eq 'M02' -and $r.dependencies.M02.Count -eq 0) 'consumption direction takes precedence over ID order'
$reverseSurfaces[0].provides = 'schema:cycle'; $reverseSurfaces[1].consumes = 'schema:cycle'
Check (((Get-MilestoneDependencyAnalysis $reverse $reverseSurfaces).errors -join ' ') -match 'DEPENDENCY_CYCLE') 'interface cycles rejected'
$bad = $surfaces[0].'write-surface'; $surfaces[0].'write-surface' = 'web/[ab].ts'
Check (((Get-MilestoneDependencyAnalysis $milestones $surfaces).errors -join ' ') -match 'DEPENDENCY_SURFACE_INVALID') 'unsupported glob syntax fails closed'
$surfaces[0].'write-surface' = $bad
Check (((Get-MilestoneDependencyAnalysis $milestones @($surfaces[0])).errors -join ' ') -match 'DEPENDENCY_SURFACE_MISSING') 'missing surfaces fail closed'

$root = Join-Path ([IO.Path]::GetTempPath()) ('dependency-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
try {
    $roadmap = Join-Path $root 'roadmap.md'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../build-roadmap.ps1') -DesignPath (Join-Path $PSScriptRoot 'fixtures/v23-dependencies.md') -RoadmapPath $roadmap -ForceMermaidFallback | Out-Null
    Check ($LASTEXITCODE -eq 0) 'producer completes'
    $generated = Get-Content $roadmap -Raw
    Check ($generated.Contains('DEPENDENCY_UNJUSTIFIED') -and $generated.Contains('serial: write overlap deploy/target_lock.py')) 'producer records removed prerequisites and overlap cause'
    Check ($generated.Contains('M02 --> M03') -and -not $generated.Contains('M01 --> M02') -and -not $generated.Contains('M01 --> M03')) 'producer graph contains only evidence-based edges'
    Check (-not $generated.Contains('| M02 | M01 | parallel') -and -not $generated.Contains('| M03 | M01 | parallel')) 'throughput copy agrees with computed dependency table'
    $v = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../roadmap-validator.ps1') -RoadmapPath $roadmap -Json) -join "`n" | ConvertFrom-Json
    Check ($v.pass) "generated fixture validates: $($v.errors -join '; ')"
    $broken = $generated.Replace('| M03 | Gate selection and per-slot locks | M02 |', '| M03 | Gate selection and per-slot locks | - |')
    Set-Content $roadmap $broken
    $v = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../roadmap-validator.ps1') -RoadmapPath $roadmap -Json) -join "`n" | ConvertFrom-Json
    Check (-not $v.pass -and ($v.errors -join ' ') -match 'DEPENDENCY_OVERLAP_UNDECLARED') 'validator catches an undeclared overlap in roadmap'
    $broken = $generated.Replace('| M02 | Host slots and deploy | - |', '| M02 | Host slots and deploy | M01 |')
    Set-Content $roadmap $broken
    $v = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../roadmap-validator.ps1') -RoadmapPath $roadmap -Json) -join "`n" | ConvertFrom-Json
    Check ($v.pass -and ($v.warnings -join ' ') -match 'DEPENDENCY_UNJUSTIFIED') 'unsupported declared dependency is a validator warning'
    Set-Content $roadmap ($generated.Replace('serial: write overlap deploy/target_lock.py <> deploy/target_lock.py', 'parallel'))
    $v = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../roadmap-validator.ps1') -RoadmapPath $roadmap -Json) -join "`n" | ConvertFrom-Json
    Check (-not $v.pass -and ($v.errors -join ' ') -match 'DEPENDENCY_OVERLAP_NOT_SERIAL') 'overlapping writers cannot claim parallel execution'
    # A new producer cannot silently recreate the old predecessor fallback.
    $design = Join-Path $root 'missing-surfaces.md'
    Set-Content $design ($raw -replace '(?ms)^## Milestone Surfaces.*?(?=^## )', '')
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../build-roadmap.ps1') -DesignPath $design -RoadmapPath $roadmap -ForceMermaidFallback | Out-Null
    $v = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../roadmap-validator.ps1') -RoadmapPath $roadmap -Json) -join "`n" | ConvertFrom-Json
    Check (-not $v.pass -and ($v.errors -join ' ') -match 'DEPENDENCY_SURFACE_MISSING') 'new producer fails validation without surfaces'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-Output "SUMMARY: $passed passed, $($failed.Count) failed"
foreach ($failure in $failed) { Write-Output "FAIL: $failure" }
if ($failed.Count) { exit 1 }
