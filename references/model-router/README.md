# Model router operator reference

The shared model router picks a model for a work category and a Codex or Claude lane. It keeps the established choices while evidence is being collected, then uses a researched table to rank eligible models. Protected work and long-form writing have stricter routing rules. `scripts/model-router/resolve-model.ps1` is the entry point; callers can request `-Json`.

Code lives in `scripts/model-router/`. Committed configuration and the starter table live in `references/model-router/`. Runtime files, including the live `router-table.json`, model registry, check stamp, research profiles, alerts, outcomes, and cost reports, are per machine. `Get-RouterStateDir` in `scripts/model-router/router-common.ps1` resolves that folder: `DT_MODEL_ROUTER_STATE` when set, otherwise the `model-router/state` sibling of the main checkout. The same state folder is used from a worktree, and its `.gitignore` containing `*` keeps its contents out of Git.

Until a full-coverage research table exists, the router stays in **bridge mode**: its first picks follow the pre-router tiers. A retry may escalate to a frontier model after the frontier-spend check. Only a valid research-sourced live table with `coverage=full` switches to evidence-based selection. An invalid live table falls back to the seed and raises an alert.

On resolution, the model catalog check runs at most once every 12 hours and has a 30-second deadline. New models are recorded and queued for research; a newly detected model also triggers a detached canary. A timed-out or failed check preserves the last good registry. Alerts show a chat line, then try a private Discord DM, with email as fallback. A delivered alert key fires once; its delivery is recorded in `alert-log.jsonl`.

`run-router-research.ps1` writes model profiles, and `build-router-table.ps1` builds the live table from those profiles. `update-outcomes.ps1` reads build outcomes, tunes measured pass rates, and flags performance drift; the resolver can demote a flagged model when an eligible alternative exists. The weekly cost report compares subscription use with estimated API-equivalent spend. The monthly canary tests selected and flagged models and records outcomes; it also runs after a newly detected model release.

At ship, register the two Windows Scheduled Tasks from the **main checkout** with `pwsh -NoProfile -File scripts/model-router/register-router-schedules.ps1 -Apply`. They run the monthly canary on day 1 at 04:00 ET and the weekly cost report on Monday at 07:00 ET. Do not register them from a build worktree.

From the repo root, run:

```powershell
Get-ChildItem scripts/model-router/tests/*.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName; if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" } }
pwsh -NoProfile -File scripts/verify-versioning-policy.ps1 -BaseRef main -Json
pwsh -NoProfile -File scripts/verify-skill-junctions.ps1 -RepoRoot (Get-Location).Path -Json
```
