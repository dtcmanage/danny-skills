param(
    [string]$SkillsRoot = "skills",
    [string]$OutputHtml = "design/skills-audit-report.html"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-TextStats {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Lines = 0
            Words = 0
            Chars = 0
            Tokens = 0
            Bytes = 0
        }
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    $lines = (Get-Content -LiteralPath $Path).Count
    $words = ([regex]::Matches($raw, "\b[\w'-]+\b")).Count
    $chars = $raw.Length
    $bytes = (Get-Item -LiteralPath $Path).Length
    return [pscustomobject]@{
        Lines = $lines
        Words = $words
        Chars = $chars
        Tokens = [math]::Ceiling($chars / 4.0)
        Bytes = $bytes
    }
}

function Get-AggregateStats {
    param([string[]]$Paths)
    $sumLines = 0
    $sumWords = 0
    $sumChars = 0
    $sumTokens = 0
    $sumBytes = 0
    foreach ($p in $Paths) {
        $s = Get-TextStats -Path $p
        $sumLines += $s.Lines
        $sumWords += $s.Words
        $sumChars += $s.Chars
        $sumTokens += $s.Tokens
        $sumBytes += $s.Bytes
    }
    return [pscustomobject]@{
        Lines = $sumLines
        Words = $sumWords
        Chars = $sumChars
        Tokens = $sumTokens
        Bytes = $sumBytes
    }
}

$skillsRootFull = Join-Path (Get-Location) $SkillsRoot
if (-not (Test-Path -LiteralPath $skillsRootFull)) {
    throw "Skills root not found: $skillsRootFull"
}

$skills = Get-ChildItem -LiteralPath $skillsRootFull -Directory | Sort-Object Name
$rows = @()

foreach ($skill in $skills) {
    $skillMd = Join-Path $skill.FullName "SKILL.md"
    if (-not (Test-Path -LiteralPath $skillMd)) { continue }

    $skillStats = Get-TextStats -Path $skillMd

    $refFiles = @()
    $refDir = Join-Path $skill.FullName "references"
    if (Test-Path -LiteralPath $refDir) {
        $refFiles = Get-ChildItem -LiteralPath $refDir -Recurse -File |
            Where-Object { $_.Extension -in @(".md", ".txt") } |
            Select-Object -ExpandProperty FullName
    }
    $refStats = Get-AggregateStats -Paths $refFiles

    $scriptFiles = @()
    $scriptDir = Join-Path $skill.FullName "scripts"
    if (Test-Path -LiteralPath $scriptDir) {
        $scriptFiles = Get-ChildItem -LiteralPath $scriptDir -Recurse -File |
            Where-Object { $_.Extension -in @(".ps1", ".py", ".js", ".ts", ".sh", ".bat") } |
            Select-Object -ExpandProperty FullName
    }
    $scriptStats = Get-AggregateStats -Paths $scriptFiles

    $assetFiles = @()
    $assetDir = Join-Path $skill.FullName "assets"
    if (Test-Path -LiteralPath $assetDir) {
        $assetFiles = Get-ChildItem -LiteralPath $assetDir -Recurse -File | Select-Object -ExpandProperty FullName
    }
    $assetBytes = 0
    foreach ($af in $assetFiles) { $assetBytes += (Get-Item -LiteralPath $af).Length }

    $allFiles = Get-ChildItem -LiteralPath $skill.FullName -Recurse -File
    $allBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
    if (-not $allBytes) { $allBytes = 0 }

    # Heuristic:
    # - prompt footprint: SKILL + 45% of references (references are often loaded conditionally)
    # - runtime surface: script lines + light penalty for more files/assets
    $effectivePromptTokens = [math]::Round($skillStats.Tokens + (0.45 * $refStats.Tokens), 0)
    $runtimeSurface = [math]::Round($scriptStats.Lines + (0.15 * $allFiles.Count) + ($assetBytes / 4096.0), 1)
    $heaviness = [math]::Round((0.65 * $effectivePromptTokens) + (0.35 * $runtimeSurface), 1)

    $rows += [pscustomobject]@{
        Skill = $skill.Name
        SkillMdLines = $skillStats.Lines
        SkillMdWords = $skillStats.Words
        SkillMdTokensEst = $skillStats.Tokens
        ReferenceFiles = @($refFiles).Count
        ReferenceLines = $refStats.Lines
        ReferenceTokensEst = $refStats.Tokens
        ScriptFiles = @($scriptFiles).Count
        ScriptLines = $scriptStats.Lines
        AssetFiles = @($assetFiles).Count
        TotalFiles = @($allFiles).Count
        TotalKb = [math]::Round($allBytes / 1024.0, 1)
        EffectivePromptTokensEst = $effectivePromptTokens
        RuntimeSurfaceScore = $runtimeSurface
        HeavinessScore = $heaviness
    }
}

$rows = $rows | Sort-Object HeavinessScore -Descending

$totalSkills = $rows.Count
$totalSkillLines = ($rows | Measure-Object -Property SkillMdLines -Sum).Sum
$totalSkillTokens = ($rows | Measure-Object -Property SkillMdTokensEst -Sum).Sum
$totalEffectivePromptTokens = ($rows | Measure-Object -Property EffectivePromptTokensEst -Sum).Sum
$totalScriptLines = ($rows | Measure-Object -Property ScriptLines -Sum).Sum

$generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
$repoRoot = (Get-Location).Path
$repoRootForPs = $repoRoot -replace "'", "''"
$refreshCommand = "cd '$repoRootForPs'; pwsh -File scripts/audit-skills-metrics.ps1"
$json = $rows | ConvertTo-Json -Depth 5

$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Skills Audit Report</title>
  <style>
    :root {
      --bg: #0f131a;
      --panel: #171d26;
      --text: #e9eef7;
      --muted: #9ba7bd;
      --line: #2a3342;
      --accent: #55d6be;
      --accent2: #6fb1ff;
      --hot: #ff7d7d;
    }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: "Segoe UI", "Aptos", system-ui, sans-serif; background: var(--bg); color: var(--text); }
    .wrap { max-width: 1300px; margin: 0 auto; padding: 22px; }
    .hero { background: linear-gradient(130deg, #171d26 0%, #1e2733 100%); border: 1px solid var(--line); border-radius: 14px; padding: 16px; }
    .hero h1 { margin: 0; font-size: 24px; }
    .meta { color: var(--muted); margin-top: 8px; font-size: 13px; }
    .cards { margin-top: 14px; display: grid; grid-template-columns: repeat(auto-fit,minmax(210px,1fr)); gap: 10px; }
    .card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 12px; }
    .card .k { color: var(--muted); font-size: 12px; }
    .card .v { margin-top: 6px; font-size: 22px; font-weight: 700; }
    .panel { margin-top: 14px; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 12px; }
    .panel h2 { margin: 0 0 8px 0; font-size: 17px; }
    .note { color: var(--muted); font-size: 12px; line-height: 1.5; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { border-bottom: 1px solid var(--line); padding: 8px; text-align: left; vertical-align: top; }
    th { color: #c8d4eb; font-weight: 600; background: #141a23; position: sticky; top: 0; }
    .num { text-align: right; font-variant-numeric: tabular-nums; }
    .bars { display: grid; gap: 8px; }
    .bar-row { display: grid; grid-template-columns: 220px 1fr 90px; gap: 8px; align-items: center; font-size: 13px; }
    .bar-track { width: 100%; height: 10px; background: #121722; border: 1px solid var(--line); border-radius: 999px; overflow: hidden; }
    .bar-fill { height: 100%; background: linear-gradient(90deg, var(--accent2), var(--accent)); }
    .bar-hot { background: linear-gradient(90deg, #ffb26b, var(--hot)); }
    .small { font-size: 12px; color: var(--muted); }
    .cmd { margin-top: 8px; background: #121722; border: 1px solid var(--line); border-radius: 10px; padding: 10px; font-family: Consolas, "Courier New", monospace; font-size: 12px; color: #d9e6ff; overflow-x: auto; white-space: nowrap; }
    .actions { margin-top: 10px; display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .btn {
      border: 1px solid #2a4d93;
      background: linear-gradient(180deg, #214f9d 0%, #1a3d7b 100%);
      color: #eaf2ff;
      border-radius: 8px;
      padding: 8px 12px;
      font-size: 12px;
      font-weight: 600;
      cursor: pointer;
    }
    .btn:hover { filter: brightness(1.08); }
    .status { font-size: 12px; color: var(--muted); }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="hero">
      <h1>Skills Audit: Size, Token Footprint, and Heaviness</h1>
      <div class="meta">Generated: $generatedAt | Repo: danny-skills | Source: skills/*</div>
      <div class="cards">
        <div class="card"><div class="k">Skills Audited</div><div class="v">$totalSkills</div></div>
        <div class="card"><div class="k">SKILL.md Lines</div><div class="v">$totalSkillLines</div></div>
        <div class="card"><div class="k">SKILL.md Tokens (est)</div><div class="v">$totalSkillTokens</div></div>
        <div class="card"><div class="k">Effective Prompt Tokens (est)</div><div class="v">$totalEffectivePromptTokens</div></div>
        <div class="card"><div class="k">Script Lines</div><div class="v">$totalScriptLines</div></div>
      </div>
    </section>

    <section class="panel">
      <h2>Refresh Command</h2>
      <p class="note">Run from repo root to regenerate this report:</p>
      <div class="cmd" id="refresh-cmd">$refreshCommand</div>
      <div class="actions">
        <button class="btn" id="copy-refresh-cmd-btn" type="button">Copy Refresh Command</button>
        <span class="status" id="copy-refresh-cmd-status"></span>
      </div>
    </section>

    <section class="panel">
      <h2>Heaviest Skills (Heaviness Score)</h2>
      <div class="bars" id="heaviness-bars"></div>
      <p class="note">Heaviness score formula: 0.65 * EffectivePromptTokensEst + 0.35 * RuntimeSurfaceScore.</p>
    </section>

    <section class="panel">
      <h2>Largest Prompt Footprint (Effective Prompt Tokens)</h2>
      <div class="bars" id="prompt-bars"></div>
      <p class="note">EffectivePromptTokensEst = SKILL.md tokens + 45% of references tokens (references are often conditional reads).</p>
    </section>

    <section class="panel">
      <h2>Per-Skill Metrics</h2>
      <div style="overflow:auto; max-height:70vh;">
        <table id="metrics">
          <thead>
            <tr>
              <th>Skill</th>
              <th class="num">SKILL.md Lines</th>
              <th class="num">SKILL.md Tokens*</th>
              <th class="num">Ref Files</th>
              <th class="num">Ref Tokens*</th>
              <th class="num">Script Files</th>
              <th class="num">Script Lines</th>
              <th class="num">Total Files</th>
              <th class="num">Total KB</th>
              <th class="num">Effective Prompt*</th>
              <th class="num">Runtime Surface</th>
              <th class="num">Heaviness</th>
            </tr>
          </thead>
          <tbody></tbody>
        </table>
      </div>
      <p class="small">* Token values are estimates from character count / 4, not model-tokenizer exact counts.</p>
    </section>
  </main>

  <script>
    const data = $json;
    const refreshCmd = document.getElementById("refresh-cmd").textContent.trim();

    const fmt = (n) => new Intl.NumberFormat().format(n);

    function renderBars(elId, key, hot=false) {
      const root = document.getElementById(elId);
      const top = [...data].sort((a,b)=>b[key]-a[key]).slice(0,10);
      const max = Math.max(...top.map(x=>x[key]), 1);
      for (const item of top) {
        const row = document.createElement("div");
        row.className = "bar-row";
        const label = document.createElement("div");
        label.textContent = item.Skill;
        const track = document.createElement("div");
        track.className = "bar-track";
        const fill = document.createElement("div");
        fill.className = "bar-fill" + (hot ? " bar-hot" : "");
        fill.style.width = ((item[key] / max) * 100).toFixed(1) + "%";
        track.appendChild(fill);
        const value = document.createElement("div");
        value.className = "num";
        value.textContent = fmt(item[key]);
        row.appendChild(label);
        row.appendChild(track);
        row.appendChild(value);
        root.appendChild(row);
      }
    }

    function renderTable() {
      const tbody = document.querySelector("#metrics tbody");
      for (const r of data) {
        const tr = document.createElement("tr");
        const cells = [
          r.Skill,
          r.SkillMdLines,
          r.SkillMdTokensEst,
          r.ReferenceFiles,
          r.ReferenceTokensEst,
          r.ScriptFiles,
          r.ScriptLines,
          r.TotalFiles,
          r.TotalKb,
          r.EffectivePromptTokensEst,
          r.RuntimeSurfaceScore,
          r.HeavinessScore
        ];
        cells.forEach((c, idx) => {
          const td = document.createElement("td");
          td.textContent = (typeof c === "number") ? fmt(c) : c;
          if (idx > 0) td.className = "num";
          tr.appendChild(td);
        });
        tbody.appendChild(tr);
      }
    }

    async function copyRefreshCommand() {
      const status = document.getElementById("copy-refresh-cmd-status");
      status.textContent = "";
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          await navigator.clipboard.writeText(refreshCmd);
        } else {
          const temp = document.createElement("textarea");
          temp.value = refreshCmd;
          temp.setAttribute("readonly", "");
          temp.style.position = "absolute";
          temp.style.left = "-9999px";
          document.body.appendChild(temp);
          temp.select();
          document.execCommand("copy");
          document.body.removeChild(temp);
        }
        status.textContent = "Copied.";
      } catch (err) {
        status.textContent = "Copy failed. Select the command text and copy manually.";
      }
    }

    document.getElementById("copy-refresh-cmd-btn").addEventListener("click", copyRefreshCommand);
    renderBars("heaviness-bars", "HeavinessScore", true);
    renderBars("prompt-bars", "EffectivePromptTokensEst", false);
    renderTable();
  </script>
</body>
</html>
"@

$outPath = Join-Path (Get-Location) $OutputHtml
$outDir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
Set-Content -LiteralPath $outPath -Value $html -Encoding UTF8

Write-Output "Wrote $outPath"
Write-Output ""
Write-Output "Top 5 skills by heaviness:"
$rows | Sort-Object HeavinessScore -Descending |
    Select-Object -First 5 Skill, SkillMdLines, EffectivePromptTokensEst, ScriptLines, HeavinessScore |
    Format-Table -AutoSize
