param(
    [Parameter(Mandatory)]
    [string]$PlanPath,

    [ValidateSet("milestone-table-only", "plan-plus-mermaid", "ui-mockup")]
    [string]$Mode = "plan-plus-mermaid",

    [string]$OutputPath = "",

    [ValidateSet("frontend-design", "web-artifacts-builder", "manual-single-variant")]
    [string]$UiMockupProvider = "web-artifacts-builder",

    [string]$UiMockupPath = "",

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
    PlanPath         = $PlanPath
    Mode             = $Mode
    UiMockupProvider = $UiMockupProvider
    UiMockupPath     = $UiMockupPath
}
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $invokeParams.OutputPath = $OutputPath
}
if ($ForceMermaidFallback) {
    $invokeParams.ForceMermaidFallback = $true
}

& $builder @invokeParams

