---
schema_version: 1
---
# Toy orchestration comparison

Copy this folder to a temporary git repository for each host/style. Use identical checks for old-style foreground execution and new-style dt-job execution. Force one coordinator rotation between M01 and M02 in the new-style run; retain run folders and collect-usage ledger rows for compare-orchestration.ps1. Never infer live acceptance from canned data.

| Milestone | Scope | Runnable check |
| :-- | :-- | :-- |
| M01 | Echo first milestone | `pwsh -NoProfile -File check.ps1 -Milestone M01` |
| M02 | Echo second milestone | `pwsh -NoProfile -File check.ps1 -Milestone M02` |
