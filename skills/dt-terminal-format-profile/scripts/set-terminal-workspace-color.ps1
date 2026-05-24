# Set a workspace-local VS Code terminal color profile in .vscode/settings.json.
# Optionally also write a companion shade to the repo's parent workstation root.

param(
    [Parameter(Mandatory)]
    [string]$Color,

    [ValidateSet("repo", "workspace", "path")]
    [string]$Scope = "repo",

    [string]$TargetPath = "",

    [switch]$AlsoSetWorkstationRoot,

    [ValidateSet("lighter", "darker", "same")]
    [string]$WorkstationVariant = "lighter",

    [string]$WorkstationColor = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$presetPalettes = @{
    "blue" = @{
        Name = "blue"
        Background = "#0c1834"
        Foreground = "#e2e8f0"
        Cursor = "#93c5fd"
        SelectionBackground = "#1d4ed8"
        SelectionForeground = "#f8fafc"
        Border = "#1e3a8a"
    }
    "navy" = @{
        Name = "navy"
        Background = "#0b1220"
        Foreground = "#e2e8f0"
        Cursor = "#7dd3fc"
        SelectionBackground = "#334155"
        SelectionForeground = "#f8fafc"
        Border = "#1f2937"
    }
    "red" = @{
        Name = "red"
        Background = "#3a0d16"
        Foreground = "#f8fafc"
        Cursor = "#fecdd3"
        SelectionBackground = "#9f1239"
        SelectionForeground = "#f8fafc"
        Border = "#be123c"
    }
    "dark-red" = @{
        Name = "dark-red"
        Background = "#18070a"
        Foreground = "#e2e8f0"
        Cursor = "#fca5a5"
        SelectionBackground = "#4a1d24"
        SelectionForeground = "#f8fafc"
        Border = "#5d1f2a"
    }
    "oxblood" = @{
        Name = "oxblood"
        Background = "#18070a"
        Foreground = "#e2e8f0"
        Cursor = "#fca5a5"
        SelectionBackground = "#4a1d24"
        SelectionForeground = "#f8fafc"
        Border = "#5d1f2a"
    }
    "burgundy" = @{
        Name = "burgundy"
        Background = "#2b0c12"
        Foreground = "#e2e8f0"
        Cursor = "#fca5a5"
        SelectionBackground = "#5d1f2a"
        SelectionForeground = "#f8fafc"
        Border = "#7f1d2d"
    }
    "teal" = @{
        Name = "teal"
        Background = "#0b1f24"
        Foreground = "#e2e8f0"
        Cursor = "#67e8f9"
        SelectionBackground = "#155e75"
        SelectionForeground = "#f8fafc"
        Border = "#0f766e"
    }
    "green" = @{
        Name = "green"
        Background = "#0f1f14"
        Foreground = "#e2e8f0"
        Cursor = "#86efac"
        SelectionBackground = "#166534"
        SelectionForeground = "#f8fafc"
        Border = "#15803d"
    }
    "purple" = @{
        Name = "purple"
        Background = "#1f1633"
        Foreground = "#ede9fe"
        Cursor = "#c4b5fd"
        SelectionBackground = "#6d28d9"
        SelectionForeground = "#f8fafc"
        Border = "#7c3aed"
    }
    "gold" = @{
        Name = "gold"
        Background = "#2b2111"
        Foreground = "#f8fafc"
        Cursor = "#fde68a"
        SelectionBackground = "#a16207"
        SelectionForeground = "#f8fafc"
        Border = "#ca8a04"
    }
    "slate" = @{
        Name = "slate"
        Background = "#111827"
        Foreground = "#e5e7eb"
        Cursor = "#93c5fd"
        SelectionBackground = "#374151"
        SelectionForeground = "#f8fafc"
        Border = "#4b5563"
    }
    "black" = @{
        Name = "black"
        Background = "#050505"
        Foreground = "#f8fafc"
        Cursor = "#ffffff"
        SelectionBackground = "#262626"
        SelectionForeground = "#f8fafc"
        Border = "#404040"
    }
}

$colorAliases = @{
    "dark red" = "dark-red"
    "deep red" = "dark-red"
    "deep-red" = "dark-red"
    "different red" = "burgundy"
    "different-red" = "burgundy"
    "light red" = "red"
    "light-red" = "red"
}

function Convert-HexToRgb {
    param([Parameter(Mandatory)][string]$HexColor)

    $value = $HexColor.Trim()
    if ($value -notmatch "^#?[0-9A-Fa-f]{6}$") {
        throw "Unsupported color '$HexColor'. Use a named preset or a hex color like #1d4ed8."
    }

    $value = $value.TrimStart("#")
    return @{
        R = [Convert]::ToInt32($value.Substring(0, 2), 16)
        G = [Convert]::ToInt32($value.Substring(2, 2), 16)
        B = [Convert]::ToInt32($value.Substring(4, 2), 16)
    }
}

function Convert-RgbToHex {
    param([Parameter(Mandatory)][hashtable]$Rgb)

    return "#{0}{1}{2}" -f `
        $Rgb.R.ToString("X2"), `
        $Rgb.G.ToString("X2"), `
        $Rgb.B.ToString("X2")
}

function Blend-HexColor {
    param(
        [Parameter(Mandatory)][string]$BaseColor,
        [Parameter(Mandatory)][string]$MixColor,
        [Parameter(Mandatory)][double]$Ratio
    )

    $base = Convert-HexToRgb -HexColor $BaseColor
    $mix = Convert-HexToRgb -HexColor $MixColor

    $blended = @{
        R = [int][Math]::Round(($base.R * (1 - $Ratio)) + ($mix.R * $Ratio))
        G = [int][Math]::Round(($base.G * (1 - $Ratio)) + ($mix.G * $Ratio))
        B = [int][Math]::Round(($base.B * (1 - $Ratio)) + ($mix.B * $Ratio))
    }

    return Convert-RgbToHex -Rgb $blended
}

function Get-ContrastForeground {
    param([Parameter(Mandatory)][string]$HexColor)

    $rgb = Convert-HexToRgb -HexColor $HexColor
    $luminance = ((0.299 * $rgb.R) + (0.587 * $rgb.G) + (0.114 * $rgb.B)) / 255
    if ($luminance -ge 0.62) {
        return "#0f172a"
    }

    return "#f8fafc"
}

function Get-RequestedPalette {
    param([Parameter(Mandatory)][string]$RequestedColor)

    $normalized = $RequestedColor.Trim().ToLowerInvariant()
    $normalized = $normalized -replace "[_]+", " "
    $normalized = $normalized -replace "\s+", " "

    if ($colorAliases.ContainsKey($normalized)) {
        $normalized = $colorAliases[$normalized]
    }

    $normalizedSlug = $normalized -replace "\s+", "-"
    if ($presetPalettes.ContainsKey($normalizedSlug)) {
        return $presetPalettes[$normalizedSlug].Clone()
    }

    $background = if ($normalizedSlug.StartsWith("#")) { $normalizedSlug } else { $RequestedColor.Trim() }
    $selectionBackground = Blend-HexColor -BaseColor $background -MixColor "#ffffff" -Ratio 0.24
    $border = Blend-HexColor -BaseColor $background -MixColor "#ffffff" -Ratio 0.16
    $cursor = Blend-HexColor -BaseColor $background -MixColor "#ffffff" -Ratio 0.58

    return @{
        Name = $RequestedColor.Trim()
        Background = (Convert-RgbToHex -Rgb (Convert-HexToRgb -HexColor $background))
        Foreground = Get-ContrastForeground -HexColor $background
        Cursor = $cursor
        SelectionBackground = $selectionBackground
        SelectionForeground = Get-ContrastForeground -HexColor $selectionBackground
        Border = $border
    }
}

function Get-VariantPalette {
    param(
        [Parameter(Mandatory)][hashtable]$BasePalette,
        [Parameter(Mandatory)][string]$Variant
    )

    if ($Variant -eq "same") {
        $samePalette = $BasePalette.Clone()
        $samePalette["Name"] = "$($BasePalette.Name)-same"
        return $samePalette
    }

    $background = switch ($Variant) {
        "lighter" {
            # Lift toward the family cursor first, then warm it slightly toward the selection tone.
            $lifted = Blend-HexColor -BaseColor $BasePalette.Background -MixColor $BasePalette.Cursor -Ratio 0.45
            Blend-HexColor -BaseColor $lifted -MixColor $BasePalette.SelectionBackground -Ratio 0.10
        }
        "darker" {
            Blend-HexColor -BaseColor $BasePalette.Background -MixColor "#000000" -Ratio 0.28
        }
        default {
            throw "Unsupported workstation variant '$Variant'."
        }
    }

    $variantPalette = Get-RequestedPalette -RequestedColor $background
    $variantPalette["Name"] = "$($BasePalette.Name)-$Variant"
    return $variantPalette
}

function Get-BaseDirectory {
    param([string]$RequestedPath)

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        return (Get-Location).Path
    }

    return (Get-Item -LiteralPath $RequestedPath).FullName
}

function Find-RepoRoot {
    param([Parameter(Mandatory)][string]$StartPath)

    $cursor = $StartPath
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath (Join-Path $cursor ".git")) {
            return $cursor
        }

        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }

    return $null
}

function Resolve-TargetRoot {
    param(
        [Parameter(Mandatory)][string]$RequestedScope,
        [string]$RequestedPath
    )

    $baseDirectory = Get-BaseDirectory -RequestedPath $RequestedPath

    switch ($RequestedScope) {
        "workspace" { return $baseDirectory }
        "path" { return $baseDirectory }
        "repo" {
            $repoRoot = Find-RepoRoot -StartPath $baseDirectory
            if (-not $repoRoot) {
                throw "Repo scope was requested, but no .git ancestor was found from '$baseDirectory'."
            }
            return $repoRoot
        }
        default {
            throw "Unsupported scope '$RequestedScope'."
        }
    }
}

function Resolve-WorkstationRoot {
    param([Parameter(Mandatory)][string]$PrimaryTargetRoot)

    $repoRoot = if (Test-Path -LiteralPath (Join-Path $PrimaryTargetRoot ".git")) {
        $PrimaryTargetRoot
    } else {
        Find-RepoRoot -StartPath $PrimaryTargetRoot
    }

    if (-not $repoRoot) {
        throw "Workstation companion mode requires the target to be a repo root or inside a repo."
    }

    $workstationRoot = Split-Path -Parent $repoRoot
    if ([string]::IsNullOrWhiteSpace($workstationRoot) -or $workstationRoot -eq $repoRoot) {
        throw "Could not resolve a parent workstation root for repo '$repoRoot'."
    }

    return $workstationRoot
}

function Get-BaselineSettings {
    return [ordered]@{
        "terminal.integrated.fontFamily" = "'Cascadia Code', 'JetBrains Mono', Consolas, 'SF Mono', 'Source Code Pro', monospace"
        "terminal.integrated.fontSize" = 14
        "terminal.integrated.lineHeight" = 1.35
        "terminal.integrated.minimumContrastRatio" = 7
        "terminal.integrated.shellIntegration.enabled" = $true
    }
}

function Get-BaselineTerminalColors {
    return [ordered]@{
        "terminal.ansiBlack" = "#1e293b"
        "terminal.ansiRed" = "#fca5a5"
        "terminal.ansiGreen" = "#86efac"
        "terminal.ansiYellow" = "#fde68a"
        "terminal.ansiBlue" = "#93c5fd"
        "terminal.ansiMagenta" = "#ddd6fe"
        "terminal.ansiCyan" = "#67e8f9"
        "terminal.ansiWhite" = "#f8fafc"
        "terminal.ansiBrightBlack" = "#64748b"
        "terminal.ansiBrightRed" = "#fda4af"
        "terminal.ansiBrightGreen" = "#6ee7b7"
        "terminal.ansiBrightYellow" = "#facc15"
        "terminal.ansiBrightBlue" = "#60a5fa"
        "terminal.ansiBrightMagenta" = "#c4b5fd"
        "terminal.ansiBrightCyan" = "#22d3ee"
        "terminal.ansiBrightWhite" = "#ffffff"
    }
}

function Read-SettingsFile {
    param([Parameter(Mandatory)][string]$SettingsPath)

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return [ordered]@{}
    }

    $raw = Get-Content -Raw -LiteralPath $SettingsPath
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    return ConvertFrom-Json -InputObject $raw -AsHashtable
}

function Ensure-Hashtable {
    param([object]$Value)

    if ($Value -is [hashtable]) {
        return $Value
    }

    return [ordered]@{}
}

function Test-MapHasKey {
    param(
        [Parameter(Mandatory)][object]$Map,
        [Parameter(Mandatory)][string]$Key
    )

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map.Contains($Key)
    }

    return $null -ne $Map.PSObject.Properties[$Key]
}

function Set-TerminalWorkspaceColor {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][hashtable]$Palette
    )

    $vscodeDirectory = Join-Path $TargetRoot ".vscode"
    $settingsPath = Join-Path $vscodeDirectory "settings.json"
    if (-not (Test-Path -LiteralPath $vscodeDirectory)) {
        New-Item -ItemType Directory -Path $vscodeDirectory | Out-Null
    }

    $settings = Read-SettingsFile -SettingsPath $settingsPath
    $baselineSettings = Get-BaselineSettings
    foreach ($entry in $baselineSettings.GetEnumerator()) {
        if (-not (Test-MapHasKey -Map $settings -Key $entry.Key)) {
            $settings[$entry.Key] = $entry.Value
        }
    }

    $colorSettings = Ensure-Hashtable -Value $settings["workbench.colorCustomizations"]
    $baselineColors = Get-BaselineTerminalColors
    foreach ($entry in $baselineColors.GetEnumerator()) {
        if (-not (Test-MapHasKey -Map $colorSettings -Key $entry.Key)) {
            $colorSettings[$entry.Key] = $entry.Value
        }
    }

    $colorSettings["terminal.background"] = $Palette.Background
    $colorSettings["terminal.foreground"] = $Palette.Foreground
    $colorSettings["terminalCursor.foreground"] = $Palette.Cursor
    $colorSettings["terminal.selectionBackground"] = $Palette.SelectionBackground
    $colorSettings["terminal.selectionForeground"] = $Palette.SelectionForeground
    $colorSettings["terminal.border"] = $Palette.Border

    $settings["workbench.colorCustomizations"] = $colorSettings

    $json = $settings | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $settingsPath -Value $json -Encoding utf8

    return [ordered]@{
        TargetRoot = $TargetRoot
        SettingsPath = $settingsPath
        Palette = $Palette.Name
        Background = $Palette.Background
    }
}

$targetRoot = Resolve-TargetRoot -RequestedScope $Scope -RequestedPath $TargetPath
$palette = Get-RequestedPalette -RequestedColor $Color
$primaryResult = Set-TerminalWorkspaceColor -TargetRoot $targetRoot -Palette $palette

Write-Output "TargetRoot: $($primaryResult.TargetRoot)"
Write-Output "SettingsPath: $($primaryResult.SettingsPath)"
Write-Output "Palette: $($primaryResult.Palette)"
Write-Output "Background: $($primaryResult.Background)"

if ($AlsoSetWorkstationRoot) {
    $workstationRoot = Resolve-WorkstationRoot -PrimaryTargetRoot $targetRoot
    $workstationPalette = if ([string]::IsNullOrWhiteSpace($WorkstationColor)) {
        Get-VariantPalette -BasePalette $palette -Variant $WorkstationVariant
    } else {
        Get-RequestedPalette -RequestedColor $WorkstationColor
    }

    $workstationResult = Set-TerminalWorkspaceColor -TargetRoot $workstationRoot -Palette $workstationPalette

    Write-Output "WorkstationRoot: $($workstationResult.TargetRoot)"
    Write-Output "WorkstationSettingsPath: $($workstationResult.SettingsPath)"
    Write-Output "WorkstationPalette: $($workstationResult.Palette)"
    Write-Output "WorkstationBackground: $($workstationResult.Background)"
}
