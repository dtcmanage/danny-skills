---
name: dt-ship
description: "One-command close-out for a finished feature: run the build/tests gate, rebase + ff-only merge to main via the shared merge machinery, push, deploy per the repo's .ship.json, PROVE the deploy is live (deployed commit hash must equal local main HEAD, plus browser-smoke on the configured routes), then purge the merged worktree and branch. Trigger on /dt-ship, 'ship it', 'push live', or 'ship and clean tree'. Do NOT use to create branches or worktrees (that is start-work), for design review (dt-review), or for build execution (dt-build)."
metadata:
  version: 0.1.0
  changelog:
    - "0.1.0 - Initial: ship.ps1 drives gate -> merge (reusing git-merge-feature's merge-feature.ps1 with -PurgeWorktree) -> purge sweep -> push -> deploy -> live proof (commit-hash probe + browser-smoke) from a per-repo .ship.json; fail-closed JSON summary; optional chaining into dt-session-audit / dt-handoff."
---

# dt-ship — Merge, Deploy, Prove Live, Clean Up

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).


The single close-out command for a finished feature. "Ship it" has historically meant four separate failure modes: deploys reported done that were not live, merged worktrees left behind, stale hardcoded host IPs, and re-asking for permission mid-chain. This skill runs the whole chain deterministically and refuses to say "shipped" until the live system proves it: the deployed commit hash must match the local `main` HEAD and every configured smoke route must pass in a real browser.

Git policy is `_Claude-Workspace\00_Resources\git-workflow.md` — pushing `main` IS the ship, the build/tests gate must pass before any merge, never force-push, never `--no-ff`. This skill does not redefine any of it; it executes it.

## Input

Optionally a branch or worktree name ("ship it" alone auto-detects: the current branch if not `main`, else the single feature branch). Danny's "ship it" / "push live" instruction is itself the approval for the entire chain — merge, push, deploy, purge. Do not re-ask at any step.

## Procedure

1. **Resolve the surface.** Identify the repo's primary tree and the feature branch/worktree in play. If Danny named it, pass it as `-Branch`; otherwise let the script auto-detect. If the script reports ambiguity (multiple candidate branches), ask which one — that is the only permitted question.

2. **Run the gate, then the chain, via the deterministic driver:**

   ```powershell
   pwsh -NoProfile -File skills/dt-ship/scripts/ship.ps1 -RepoRoot "<repo path>" -Branch "<name>" -Json
   ```

   The script, fail-closed (the first failing step stops everything and names itself in `failed_step`):
   - loads the repo's ship config at `<primary>\.ship.json` (schema: `references/ship-config.md`; override with `-ConfigPath`),
   - runs the config's `gateCommand` (build/tests) inside the feature worktree — a red gate means NOT merged, NOT shipped,
   - merges by calling `skills/git-merge-feature/scripts/merge-feature.ps1 -PurgeWorktree` (rebase, ff-only merge, branch delete, worktree removal — the shared machinery, never reimplemented),
   - sweeps for leftovers: any surviving worktree or branch for the merged feature is removed, but only when fully merged and clean,
   - pushes `main` to origin (pushing `main` IS the ship),
   - deploys via `deployCommand`, substituting `{HOST}` from `hostResolveCommand` output so a moved VM IP can never go stale in config,
   - probes `prodCommitProbe` (url or command) for the deployed commit hash and compares it to the local `main` HEAD,
   - runs the browser-smoke harness (`00_Resources\tools\browser-smoke\smoke.mjs`) against every `smokeRoutes` URL,
   - emits one JSON summary: `status`, `failed_step`, `merged`, `pushed`, `deployed`, `hash_match`, `local_head`, `prod_commit`, `smoke [{route, pass}]`, `purged`, `skipped`, `rerere_enabled`.

   If no `gateCommand` is configured, run the repo's build/tests yourself in the feature worktree BEFORE invoking the script; only invoke it on green. Never invoke `-SkipGate` unless you just ran the gate by hand and it passed.

3. **No ship config?** If `.ship.json` does not exist, the script still merges, purges, and pushes, then exits with `status: merged_only` and `deploy`/`verify-hash`/`smoke` in `skipped`. Report exactly that: "merged and pushed, but deploy and live verification were SKIPPED — this repo has no ship config," and offer to scaffold a `.ship.json` from the worked examples in `references/ship-config.md`.

4. **Interpret the result honestly.**
   - `status: shipped` — hash matched and every smoke route passed. Only now may you say it is shipped.
   - `status: not_shipped` — the hash mismatched or a smoke route failed. Report LOUDLY: "NOT SHIPPED" leads the response, with the mismatched hashes or failing routes and screenshots from the smoke harness. Then drive to a fix — do not stop at the diagnosis.
   - `status: merged_only` — merged and pushed, deploy/verify skipped (no config).
   - `status: failed` — report `failed_step` and `error_message`; nothing after that step ran.

5. **Report a verification table.** One row per claim: what was done, how it was checked, and the concrete evidence. At minimum: gate (command + exit code), merge (commit range), push (origin main), deploy (command exit), hash proof (`prod_commit` vs `local_head`), each smoke route (pass + screenshot path), purge (worktrees/branches removed — quote `purged`, and confirm `git worktree list` shows only the primary tree). If `rerere_enabled` is `false`, suggest `git config --global rerere.enabled true`.

6. **Chain if asked.** If Danny's request included an audit or handoff ("ship it and audit sess", "ship and hand off"), invoke `dt-session-audit` / `dt-handoff` after the ship report — a model step, not part of the script.

## Rules

- Never force-push, never `--no-ff`, never rewrite history. The script only ever fast-forward pushes `main`.
- Never skip the gate. A red or unrun gate means the merge does not happen.
- Never claim shipped without the live proof: `hash_match: true` AND all smoke routes passing. "The deploy command exited 0" is not shipped.
- The "ship it" instruction is the single approval for the whole chain. Do not re-ask before the merge, the push, the deploy, or the purge.
- This skill never creates branches or worktrees (that is `start-work`) and never does design review (that is `dt-review`).
- Purge is safe-by-construction: worktrees and branches are removed only after a confirmed ff-only merge and only when the tree is clean. Never remove a worktree another live session may still be in.
- `-SkipDeploy` (deploy already ran externally) still runs the hash probe and smoke — the proof is never optional when a config exists. `-SkipPush` is for deliberately local-only repos only.
