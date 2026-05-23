# Render a design-view HTML artifact by diffing plan-draft.md vs design-final.md.

param(
    [Parameter(Mandatory)]
    [string]$PlanPath,

    [Parameter(Mandatory)]
    [string]$DesignPath,

    [string]$OutputPath = "",

    [switch]$ForceMermaidFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
$resolved = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolved) { $skillRoot = $resolved.FullName }

$repoRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)
$builder = Join-Path $repoRoot "scripts\visualize\html-builder.ps1"

if (-not (Test-Path -LiteralPath $builder)) {
    throw "Builder script not found: $builder"
}

$invokeParams = @{
    PlanPath   = $PlanPath
    DesignPath = $DesignPath
    Mode       = "design-diff"
}
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $invokeParams.OutputPath = $OutputPath
}
if ($ForceMermaidFallback) {
    $invokeParams.ForceMermaidFallback = $true
}

& $builder @invokeParams
