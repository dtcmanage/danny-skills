# Usage telemetry (automatic)

Moved from `SKILL.md` "Usage telemetry" (2026-11-23) to keep `SKILL.md` under its word cap; the rules are unchanged.

`<danny-skills>/scripts/collect-usage.ps1` sweeps this machine's Claude Code and Codex session logs for dt-build runs
(orchestrators and wrapper-launched chunks, either host) and refreshes
`Skill Creation/dt-build-token-efficiency/usage/usage-ledger-<machine>.jsonl` plus `usage-dashboard.html`:
weighted tokens by model family, peak context, nested agents, resume messages, idle cache losses, and
Opus share per run. It is read-only against the logs, incremental, and never blocks a build.

- Run `pwsh -NoProfile -File "<skill>/scripts/collect-usage.ps1" -Quiet` once at intake (step 1) and once after the
  final ledger (step 6.5). The intake sweep is what captures earlier runs, including ones that never
  reached COMPLETE; there is no separate manual step.
- Relay any `DT_BUILD_USAGE_ALERT:` line to Danny verbatim, once. Alerts fire only the first time a run is
  flagged. They are advisory: never stop, retry, or re-plan a build because of one.
- Do not read the ledger or dashboard into your context; report the dashboard path only.
