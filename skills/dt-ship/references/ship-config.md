# .ship.json — Per-Repo Ship Config for dt-ship

Lives at the repo's primary-tree root: `<repo>\.ship.json`. Read by `skills/dt-ship/scripts/ship.ps1` (override the location with `-ConfigPath`). No config means dt-ship stops after merge + purge + push (`status: merged_only`) — deploy and live verification are skipped and reported as skipped.

## Schema

| Key | Type | Required | Meaning |
| :---- | :---- | :---- | :---- |
| `deployCommand` | string | yes | PowerShell command line that performs the deploy. Run via `pwsh -NoProfile -Command`. `{HOST}` is substituted before execution. Nonzero exit = ship fails at `deploy`. |
| `deployCwd` | string | no | Working directory for `deployCommand`. Absolute, or relative to the repo's primary tree. Default: the primary tree. |
| `prodCommitProbe` | object | yes | How to read the commit hash that is actually live. Exactly one of: `url` — an HTTP(S) endpoint whose body contains the deployed commit SHA (e.g. a `version.json`); `command` — a PowerShell command whose output contains it (e.g. an ssh `cat RELEASE_SHA`). The first 40-hex (falling back to 7-40-hex word) match is compared against local `main` HEAD. No hash or a mismatch = `status: not_shipped`. `{HOST}` is substituted in both forms. |
| `smokeRoutes` | array of strings | no | URLs the browser-smoke harness must pass after the hash check (Playwright Chromium; fails on missing page, console errors, page errors, failed document/script/css/fetch/xhr requests). `{HOST}` is substituted. Empty/absent = smoke is skipped (recorded in `skipped`). |
| `hostResolveCommand` | string | no | PowerShell command whose last output line is the current host (IP or DNS name). Its output replaces every `{HOST}` token in `deployCommand`, `prodCommitProbe`, and `smokeRoutes`. This is the fix for stale hardcoded VM IPs: resolve the address live at ship time, never bake it into config. Required if any value uses `{HOST}`. |
| `gateCommand` | string | no | Build/tests command run inside the feature worktree BEFORE the merge. Nonzero exit = nothing merges. If absent, the model must run the gate by hand before invoking `ship.ps1`. |
| `smokeHarnessPath` | string | no | Override for the smoke harness. Default: `D:\Claude\_Claude-Workspace\00_Resources\tools\browser-smoke\smoke.mjs`. |

All strings use plain ASCII quotes. `{HOST}` is the only substitution token.

## Example 1 — Cloudflare/wrangler-style web deploy (thai-capital-website)

The website repo already owns its deploy logic in its own `ship.ps1`; the ship config just calls it. The probe reads the commit hash the site publishes at build time; smoke covers the pages that have historically been reported live when they were not.

```json
{
  "gateCommand": "npm run build",
  "deployCommand": "pwsh -NoProfile -File .\\ship.ps1",
  "deployCwd": ".",
  "prodCommitProbe": {
    "url": "https://thaicapital.com/version.json"
  },
  "smokeRoutes": [
    "https://thaicapital.com/",
    "https://thaicapital.com/tearsheet"
  ]
}
```

Requirement on the repo side: the build must emit the current commit SHA into a publicly served file (e.g. `public/version.json` containing `{"commit": "<sha>"}` written from `git rev-parse HEAD` in the build step). Without a live commit endpoint there is no hash proof and dt-ship cannot report `shipped`.

## Example 2 — SSH-to-VM deploy with live IP resolution (tcm-dashboard-01 style)

The VM's public IP is never hardcoded: `hostResolveCommand` asks Azure for it at ship time and the result replaces `{HOST}` everywhere. The deploy pipes a repo-local `deploy.sh` to the VM (per the multi-host rule: no heredocs into PowerShell); the probe reads the SHA the deploy script stamps on the box.

```json
{
  "gateCommand": "python -m pytest tests",
  "hostResolveCommand": "az vm show -d -g tcm-rg -n tcm-dashboard-01 --query publicIps -o tsv",
  "deployCommand": "Get-Content .\\deploy.sh -Raw | ssh azureuser@{HOST} 'bash -s'",
  "deployCwd": ".",
  "prodCommitProbe": {
    "command": "ssh azureuser@{HOST} 'cat /opt/app/RELEASE_SHA'"
  },
  "smokeRoutes": [
    "http://{HOST}:8080/health",
    "http://{HOST}:8080/dashboard"
  ]
}
```

Requirement on the repo side: `deploy.sh` must end by writing the deployed commit SHA to the probed location, e.g. `git -C /opt/app rev-parse HEAD > /opt/app/RELEASE_SHA` (or copy the SHA it deployed). The probe then proves the box is running exactly what just merged to `main`.

## Scaffolding a new config

When dt-ship reports `merged_only` (no config), offer to scaffold: pick the example that matches the repo's deploy shape, fill in the real commands, and add the commit-SHA publication step to the build/deploy if it does not exist yet. Commit `.ship.json` to the repo — it is per-repo config, not skill config.
