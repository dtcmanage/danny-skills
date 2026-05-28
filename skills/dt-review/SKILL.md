---
name: dt-review
description: "Adversarial Claude-vs-Codex design dialogue on a plan. Trigger on /dt-review or 'dt-review [plan-path]'. Do NOT use for small bug fixes or single-file edits."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(codex:*) Bash(git:*) Bash(pwsh:*) Read Write Edit AskUserQuestion"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.2.1
  changelog: "Effort tuning: all tiers now default to `medium` reasoning effort (LIGHT/PREFLIGHT raised from low; COMPLEX unchanged). Prior: 1.2.0 execution-model fix — codex rounds run via the Bash tool as `pwsh -NoProfile -File` with the prompt on stdin, fixing the 70-min PowerShell-tool host hang, the ConstrainedLanguage profile crash, and the ~30KB arg-length failure that dropped round output; added per-tier `-ReasoningEffort` to override the global `model_reasoning_effort=high`."
---

# Review — Claude x Codex Coworker Dialogue

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

`dt-review` is adversarial design critique for a plan. Two engineers debate the design as equals across
rounds until it converges or the cap is reached.

Persistent output:
- `design/design-final.md`

Scratch-only review state during an active run:
- `design\_review\draft-v<N>.md`
- `design\_review\review-v<N>.md`
- `design\_review\codex-stream-v<N>.log`
- `design\_review\prompts\codex-critique-prompt-v<N>.md`

Scratch state exists only to support an interrupted in-progress review. Delete it after successful
finalization. If Danny wants a retained HTML view after finalization, that is `dt-visualize-design`,
not `dt-review`.

## When this fires

Trigger when at least one is true:
- New system/service/major component with hard-to-reverse architectural commitments.
- Non-trivial refactor (touches >3 modules or changes a contract).
- New external integration where failure/security/operability paths must be pressure-tested.

Do NOT fire for:
- Bug fixes, copy edits, single-file tweaks, throwaway experiments.
- Build execution from a finalized plan (`dt-build`).
- Initial planning (`dt-plan`) or behavior/UI prototyping (`dt-prototype`).

## Operating constants

These constants are the single source of truth for which Codex model and reasoning effort each tier uses.
Always pass the matching `-Model` and `-ReasoningEffort` to every script — the script defaults are a
fallback, not the contract. Use them unless Danny explicitly overrides:
- `LIGHT_MODEL = gpt-5.3-codex` — fast codex-tuned tier (light rounds + preflight). Best available fast
  model on ChatGPT-subscription auth; the codex-tuned successor `gpt-5.5-codex` is blocked there, so this
  stays the fast pin.
- `LIGHT_EFFORT = medium`
- `COMPLEX_MODEL = gpt-5.5` — deep-reasoning tier for hard architectural rounds. Supersedes `gpt-5.4`.
- `COMPLEX_EFFORT = medium` — bump to `high` only for the hardest architectural rounds; `high` is
  materially slower and burns far more subscription quota.
- `PREFLIGHT_MODEL = gpt-5.3-codex`
- `PREFLIGHT_EFFORT = medium`
- `PREFLIGHT_TIMEOUT_MS = 30000`
- `HANG_GUARD_MS = 1800000`

Reasoning effort matters: Danny's `~/.codex/config.toml` sets `model_reasoning_effort = "high"` globally,
so without an explicit `-ReasoningEffort` every round — even the preflight "reply OK" — runs a full
deep-reasoning pass (tens of thousands of tokens, minutes of wall time). The scripts pass
`-c model_reasoning_effort=<effort>` to override the global default per invocation.

Model freshness: when OpenAI ships a new Codex model, re-probe availability on Danny's auth per the
workspace Codex matrix (`_Claude-Workspace\00_Resources\codex-cli-usage.md`) with a read-only "reply OK"
probe, then update the pins above and that matrix in the same pass. Pin explicitly; never rely on Codex's
auto-migrated config default, which can drift silently.

## Canonical contracts and references

Read these files on demand from this skill folder and repo root:
- `references/input-modes.md` — intake and Round 0 mode selection (A/B/C).
- `references/codex-prompt-template.md` — codex critique template and required verdict format.
- `references/recovery.md` — interrupted-round resume rules and malformed feedback handling.
- `references/finalization.md` — finalization, glossary reconciliation, promotion-gate workflow.
- `references/design-shape.md` — `shape_version` policy + output schema for `design-final.md`.
- `../../references/canonical-dimension-contract.md` — single canonical Dimension Contract source.

Never inline-copy the Canonical Dimension Contract into this SKILL.md. Pointer-swap is mandatory.

## Execution model — how to run the scripts

This is load-bearing. Get it wrong and a round hangs for over an hour or silently produces no output.

1. **Run every dt-review script through the Bash tool, never the PowerShell tool.** Codex hangs
   indefinitely when launched from Claude's PowerShell tool (its host has redirected stdio and no real
   console); a stuck round can sit for 70+ minutes. Launched from the Bash tool, Codex gets clean stdio
   and returns normally. Invocation shape:

   ```
   pwsh -NoProfile -File "<abs path>/skills/dt-review/scripts/<script>.ps1" -ProjectPath "<abs>" ...
   ```

2. **`-NoProfile` is mandatory.** Danny's PowerShell profile dot-sources helpers under ConstrainedLanguage
   and crashes the script ("Cannot dot-source ... defined in a different language mode") if the profile loads.
3. **Wrap the Bash call in a timeout** — `PREFLIGHT_TIMEOUT_MS` for preflight, `HANG_GUARD_MS` for a round.
4. **The prompt goes to Codex over stdin, handled inside the scripts.** Never pass a round prompt as a
   command-line argument: it is ~30KB+ and overruns the OS arg-length limit, so the round output is lost.
5. **Pass `-Model` and `-ReasoningEffort`** from the operating constants for the active tier.

The pure-PowerShell scripts (`parse-verdict.ps1`, `capture-provenance.ps1`) do no Codex I/O and may run
either way, but run them via Bash too for consistency.

## Procedure

### Step 1 — Combined intake

Run one `AskUserQuestion` that captures:
- Project name (when not inferable from a provided plan path)
- Workstation (when not inferable)
- Tier (`light` or `complex`)
- Optional model override

Then apply Mode A/B/C from `references/input-modes.md` and write scratch `draft-v1.md` verbatim from the
selected source.

### Step 2 — Pre-flight

Run `scripts/preflight-codex.ps1` before Round 1, via Bash per the Execution model section:
`pwsh -NoProfile -File <...>/preflight-codex.ps1 -ProjectPath <abs> -Model PREFLIGHT_MODEL -ReasoningEffort PREFLIGHT_EFFORT`,
wrapped in a `PREFLIGHT_TIMEOUT_MS` timeout. If it does not return `OK` in 30 seconds, stop and surface the
error.

### Step 3 — Round N loop

For each round N:
1. Announce round start in chat with model.
2. Assemble the codex prompt using `references/codex-prompt-template.md` and the canonical dimension
   contract from `../../references/canonical-dimension-contract.md`.
3. Execute `scripts/invoke-codex-round.ps1` via Bash per the Execution model section
   (`pwsh -NoProfile -File <...>/invoke-codex-round.ps1 -ProjectPath <abs> -Round <N> -PromptPath <abs>
   -Model <tier model> -ReasoningEffort <tier effort>`, wrapped in a `HANG_GUARD_MS` timeout) to run codex
   and write scratch `review-v<N>.md` plus scratch stream log atomically under `design\_review\`. The script
   pipes the prompt to codex over stdin.
4. Parse verdict via `scripts/parse-verdict.ps1`.
5. Reconcile each finding (ACCEPT / REJECT / DEFER / COUNTER), appending a `## Claude Response`
   section to the same scratch `review-v<N>.md` artifact.
6. If a previously REJECTed finding is raised again in the immediately following round, pause and ask Danny
   using A/B/C adjudication:
   - A = accept Codex's point now
   - B = keep rejection with new rationale
   - C = defer to open question
7. Write scratch `draft-v<N+1>.md` only when termination rules indicate continuation or one final polish pass.

### Step 4 — Output-shape obligations (Phase 4 addition)

All retained final outputs use `shape_version: 1` frontmatter per `references/design-shape.md`.

`design-final.md` is the accepted design body only. Do not copy round-by-round archaeology, stream-log
references, or review summaries into the retained final artifact.

### Step 5 — Finalization

Run the finalization workflow from `references/finalization.md`:
- copy accepted draft to `design-final.md`
- reconcile `CONTEXT.md` glossary against `design-final.md`
- delete `design\_review\` scratch state after successful finalization
- list retained output paths as bare absolute paths

## Deterministic scripts

This skill uses extracted deterministic scripts:
- `scripts/preflight-codex.ps1`
- `scripts/invoke-codex-round.ps1`
- `scripts/parse-verdict.ps1`
- `scripts/capture-provenance.ps1`

All external-text prompt assembly goes through repo-level `scripts/wrap-prompt-envelope.ps1`.
All stream/log redaction goes through repo-level `scripts/security/redact-secrets.ps1`.

## Guardrails

- Do not edit scratch `draft-v<N>.md` after codex reviews it; only write a new version.
- Use `--sandbox read-only` for codex rounds; no codebase writes from codex in this skill.
- Keep round-state reconstructible only while the review is active; do not preserve scratch review
  artifacts after a successful freeze unless Danny explicitly asks.
- Verdict parsing is line-contract based (`VERDICT:` + `Confidence:`), not heading-based.
- If feedback is malformed during recovery, archive to `.partial.<timestamp>.md` and re-run round invoke.
- Keep SKILL.md under 5,000 words; long procedural detail belongs in `references/` and scripts.
