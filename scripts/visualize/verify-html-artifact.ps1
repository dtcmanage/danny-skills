# verify-html-artifact.ps1
#
# Shared deterministic verifier for browser-openable HTML review artifacts
# (plan-view.html, design-view.html, roadmap-view.html, and any future
# HTML companion). Replaces the hand-run "open it in a browser and eyeball
# .mermaid svg" checklists in the dt-visualize-* and dt-roadmap skills.
#
# Checks (all deterministic):
#   1. file_exists          - file exists and is non-trivial in size.
#   2. no_remote_urls       - no http(s):// URL in any src/href attribute
#                             (allowlist: none; vendored/local assets only).
#   3. require_text:<...>   - one check per -RequireText string; the literal
#                             string must appear in the raw HTML (use for
#                             provenance footers, change-summary badges, etc.).
#   4. mermaid_smoke        - (-RequireMermaid) drives the shared browser-smoke
#                             harness (Playwright Chromium) against the file://
#                             URL: fails on console errors, page errors, and
#                             request failures.
#   5. mermaid_svg_rendered - (-RequireMermaid) asserts at least one rendered
#                             `.mermaid svg` element exists in the live DOM;
#                             raw Mermaid graph text does not pass.
#
# Output: JSON object { status: "pass"|"fail", checks: [{name, pass, detail}] }.
#   -Json emits compact single-line JSON; default is indented JSON.
#   Exit code 0 on pass, 1 on any failed check.
#
# Invocation (always via the Bash tool, per skill conventions):
#   pwsh -NoProfile -File scripts/visualize/verify-html-artifact.ps1 `
#     -Path <abs>.html -RequireMermaid -RequireText 'Dependency Provenance' -Json

param(
    [Parameter(Mandatory)]
    [string]$Path,

    [switch]$RequireMermaid,

    [string[]]$RequireText = @(),

    [switch]$Json,

    [int]$MinBytes = 512,

    [string]$SmokeScript = 'D:\Claude\_Claude-Workspace\00_Resources\tools\browser-smoke\smoke.mjs',

    [int]$TimeoutMs = 30000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    [void]$checks.Add([pscustomobject]@{ name = $Name; pass = $Pass; detail = $Detail })
}

# --- 1. file exists + non-trivial size -------------------------------------
$fileOk = $false
$raw = ''
if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -ge $MinBytes) {
        $fileOk = $true
        Add-Check 'file_exists' $true "exists, $($item.Length) bytes"
    } else {
        Add-Check 'file_exists' $false "file is trivially small ($($item.Length) bytes < $MinBytes minimum)"
    }
} else {
    Add-Check 'file_exists' $false "file not found: $Path"
}

if ($fileOk) {
    $raw = Get-Content -LiteralPath $Path -Raw

    # --- 2. no remote/CDN URLs in src/href ---------------------------------
    $remoteMatches = [regex]::Matches($raw, '(?i)\b(?:src|href)\s*=\s*["'']?(https?://[^"''\s>]+)')
    if ($remoteMatches.Count -eq 0) {
        Add-Check 'no_remote_urls' $true 'no http(s):// src/href references (vendored/local assets only)'
    } else {
        $urls = ($remoteMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique -First 5) -join ', '
        Add-Check 'no_remote_urls' $false "remote URL(s) referenced (allowlist is empty): $urls"
    }

    # --- 3. caller-specified literal-text assertions ------------------------
    foreach ($needle in $RequireText) {
        if ([string]::IsNullOrEmpty($needle)) { continue }
        $found = $raw.Contains($needle)
        $label = 'require_text:' + $needle
        if ($found) {
            Add-Check $label $true 'literal text present'
        } else {
            Add-Check $label $false 'literal text NOT found in HTML'
        }
    }

    # --- 4 + 5. rendered-Mermaid verification via browser-smoke harness -----
    if ($RequireMermaid) {
        if (-not (Test-Path -LiteralPath $SmokeScript -PathType Leaf)) {
            Add-Check 'mermaid_smoke' $false "browser-smoke harness not found: $SmokeScript"
            Add-Check 'mermaid_svg_rendered' $false 'skipped: browser-smoke harness unavailable'
        } else {
            $fileUrl = ([System.Uri](Resolve-Path -LiteralPath $Path).Path).AbsoluteUri
            $smokeDir = Split-Path -Parent $SmokeScript

            # 4. smoke run: console errors, page errors, request failures.
            $smokeOut = & node $SmokeScript --url $fileUrl --no-screenshot --timeout-ms $TimeoutMs 2>&1
            $smokeExit = $LASTEXITCODE
            $smokeText = ($smokeOut | Out-String).Trim()
            $smokeSummary = $null
            try { $smokeSummary = $smokeText | ConvertFrom-Json } catch { }
            if ($smokeExit -eq 0 -and $null -ne $smokeSummary -and $smokeSummary.ok) {
                Add-Check 'mermaid_smoke' $true 'browser-smoke pass: no console errors, page errors, or request failures'
            } else {
                $why = if ($null -ne $smokeSummary -and $smokeSummary.PSObject.Properties['failures']) {
                    (@($smokeSummary.failures) -join '; ')
                } else {
                    ($smokeText -split "`r?`n" | Select-Object -First 3) -join ' | '
                }
                Add-Check 'mermaid_smoke' $false "browser-smoke failed (exit $smokeExit): $why"
            }

            # 5. DOM probe: .mermaid svg rendered. Uses the browser-smoke
            # install's own Playwright dependency (createRequire against its
            # package.json), so there is no second Playwright install to drift.
            $probePath = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-html-mermaid-probe-{0}.mjs" -f ([guid]::NewGuid().ToString('N')))
            $probe = @'
import { createRequire } from "node:module";
const requireFrom = createRequire(process.env.SMOKE_PKG);
const { chromium } = requireFrom("playwright");
const url = process.env.TARGET_URL;
const timeoutMs = Number(process.env.PROBE_TIMEOUT_MS || "15000");
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  page.setDefaultTimeout(timeoutMs);
  await page.goto(url, { waitUntil: "load" });
  let svgCount = 0;
  try {
    await page.waitForSelector(".mermaid svg", { timeout: timeoutMs });
    svgCount = await page.locator(".mermaid svg").count();
  } catch {
    svgCount = 0;
  }
  const rawTextLeak = await page.locator(".mermaid:not(:has(svg))").count();
  console.log(JSON.stringify({ svgCount, unrenderedMermaidBlocks: rawTextLeak }));
} finally {
  await browser.close();
}
'@
            Set-Content -LiteralPath $probePath -Value $probe -Encoding UTF8
            try {
                $env:SMOKE_PKG = Join-Path $smokeDir 'package.json'
                $env:TARGET_URL = $fileUrl
                $env:PROBE_TIMEOUT_MS = "$TimeoutMs"
                $probeOut = & node $probePath 2>&1
                $probeExit = $LASTEXITCODE
                $probeText = ($probeOut | Out-String).Trim()
                $probeResult = $null
                try { $probeResult = $probeText | ConvertFrom-Json } catch { }
                if ($probeExit -eq 0 -and $null -ne $probeResult -and [int]$probeResult.svgCount -ge 1 -and [int]$probeResult.unrenderedMermaidBlocks -eq 0) {
                    Add-Check 'mermaid_svg_rendered' $true "$($probeResult.svgCount) rendered .mermaid svg element(s), 0 unrendered blocks"
                } elseif ($probeExit -eq 0 -and $null -ne $probeResult) {
                    Add-Check 'mermaid_svg_rendered' $false "svgCount=$($probeResult.svgCount), unrendered .mermaid blocks=$($probeResult.unrenderedMermaidBlocks) (raw graph text does not satisfy the contract)"
                } else {
                    $why = ($probeText -split "`r?`n" | Select-Object -First 3) -join ' | '
                    Add-Check 'mermaid_svg_rendered' $false "probe failed (exit $probeExit): $why"
                }
            } finally {
                Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
                Remove-Item Env:\SMOKE_PKG, Env:\TARGET_URL, Env:\PROBE_TIMEOUT_MS -ErrorAction SilentlyContinue
            }
        }
    }
} elseif ($RequireMermaid) {
    Add-Check 'mermaid_smoke' $false 'skipped: file check failed'
    Add-Check 'mermaid_svg_rendered' $false 'skipped: file check failed'
}

$allPass = -not ($checks | Where-Object { -not $_.pass })
$result = [pscustomobject]@{
    status = if ($allPass) { 'pass' } else { 'fail' }
    path   = (Test-Path -LiteralPath $Path) ? (Resolve-Path -LiteralPath $Path).Path : $Path
    checks = $checks.ToArray()
}

if ($Json) {
    $result | ConvertTo-Json -Depth 5 -Compress
} else {
    $result | ConvertTo-Json -Depth 5
}

if (-not $allPass) { exit 1 }
exit 0
