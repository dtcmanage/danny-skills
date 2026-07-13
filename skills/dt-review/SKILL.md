---
name: dt-review
description: "Adversarial Claude-vs-Codex design dialogue on a plan. Trigger on /dt-review or 'dt-review [plan-path]'. Do NOT use for small bug fixes or single-file edits."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(codex:*) Bash(git:*) Bash(pwsh:*) Read Write Edit AskUserQuestion"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.6.2
  changelog: "Changelog moved to CHANGELOG.md; newest entries first."
---

# Review — Claude x Codex Coworker Dialogue

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

`dt-review` is adversarial design critique for a plan. Two engineers debate the design as equals across
rounds until it converges or the cap is reached.

Persistent output:
- `design/design-final-<slug>.md` — the single retained design document, written ONCE at convergence.
  Rounds never write a design document; per-round output lives in scratch only. `<slug>` is 2-4
  kebab-case words derived from the plan/project name (e.g. a plan named "LP Statement Linking"
  finalizes as `design-final-lp-statement-linking.md`). Never write a bare `design-final.md` — that
  name survives only as a legacy input accepted by downstream consumers (`dt-roadmap`, `dt-build`,
  `dt-visualize-design`).

Scratch-only review state during an active run:
- `design\_review\draft-v<N>.md`
- `design\_review\review-v<N>.md`
- `design\_review\verdicts.json` (per-round parsed verdicts + finding dispositions)
- `design\_review\codex-stream-v<N>.log`
- `design\_review\prompts\codex-critique-prompt-v<N>.md`

Scratch state exists only to support an interrupted in-progress review. Delete it after successful
finalization (Finalization step 3 is the explicit checklisted cleanup). If Danny wants a retained
HTML view after finalization, that is `dt-visualize-design`, not `dt-review` — and only when Danny
explicitly asks for it.

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
Always pass the matching `-Model`, `-Tier`, and `-ReasoningEffort` to every script — the script defaults are a
fallback, not the contract. Use them unless Danny explicitly overrides:
- `STANDARD_MODEL = gpt-5.6-terra` (`-Tier standard`) — balanced everyday review tier.
- `STANDARD_EFFORT = medium`
- `COMPLEX_MODEL = gpt-5.6-sol` (`-Tier complex`) — frontier tier for hard architectural rounds.
- `COMPLEX_EFFORT = medium` — bump to `high` only for the hardest architectural rounds; `high` is
  materially slower and burns far more subscription quota.
- `PREFLIGHT_MODEL = gpt-5.6-terra`
- `PREFLIGHT_EFFORT = medium`
- `PREFLIGHT_TIMEOUT_MS = 30000`
- `HANG_GUARD_MS = 1800000`

Reasoning effort matters: the global Codex effort can change independently of this skill, so without an
explicit `-ReasoningEffort` even a preflight can inherit unnecessarily expensive compute. The scripts pass
`-c model_reasoning_effort=<effort>` to override the global default per invocation.

Self-healing model resolution: the scripts do NOT trust these pins blindly. Both `preflight-codex.ps1` and
`invoke-codex-round.ps1` call the shared `scripts/resolve-codex-model.ps1` (`Resolve-CodexModel -Tier
<standard|complex> -PreferredModel <pin>`), which reads Codex's live per-account model cache
(`~/.codex/models_cache.json`), prefers the pin when it is still selectable, and otherwise falls back
through a curated per-tier candidate list. If the pin has gone API-only (the historical `gpt-5.1-codex-max`
failure), the round still runs on a live model and a warning names the dead pin. If nothing in the
candidate list resolves, the script throws an actionable error listing what IS selectable — instead of
writing a failure log that looks like a critique. This makes the skill immune to both pin rot and the
config-default drift that bites any hand-rolled `codex exec` call that omits `--model`.

Model freshness: when OpenAI ships a new Codex model, re-probe availability on Danny's auth per the
workspace Codex matrix (`_Claude-Workspace\00_Resources\codex-cli-usage.md`) with a read-only "reply OK"
probe, then update the pins above, the candidate lists in `scripts/resolve-codex-model.ps1`, and that
matrix in the same pass. Pin explicitly; never rely on Codex's auto-migrated config default, which can
drift silently.

## Canonical contracts and references

Read these files on demand from this skill folder and repo root:
- `references/input-modes.md` — intake and Round 0 mode selection (A/B/C).
- `references/codex-prompt-template.md` — codex critique template and required verdict format.
- `references/recovery.md` — interrupted-round resume rules and malformed feedback handling.
- `references/finalization.md` — finalization, glossary reconciliation, promotion-gate workflow.
- `references/design-shape.md` — `shape_version` policy + output schema for `design-final-<slug>.md`.
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
5. **Pass `-Model`, `-Tier`, and `-ReasoningEffort`** from the operating constants for the active tier.
   `-Tier` (`standard` or `complex`) drives the self-healing fallback chain when the pinned `-Model` is no
   longer selectable on the current auth (see the operating-constants "Self-healing model resolution" note).

The pure-PowerShell scripts (`parse-verdict.ps1`, `capture-provenance.ps1`) do no Codex I/O and may run
either way, but run them via Bash too for consistency.

## Procedure

### Step 1 — Combined intake

Run one `AskUserQuestion` that captures:
- Project name (when not inferable from a provided plan path)
- Workstation (when not inferable)
- Tier (`standard` or `complex`)
- Optional model override

Then apply Mode A/B/C from `references/input-modes.md` and write scratch `draft-v1.md` verbatim from the
selected source.

### Step 2 — Pre-flight

Run `scripts/preflight-codex.ps1` before Round 1, via Bash per the Execution model section:
`pwsh -NoProfile -File <...>/preflight-codex.ps1 -ProjectPath <abs> -Model PREFLIGHT_MODEL -Tier standard -ReasoningEffort PREFLIGHT_EFFORT`,
wrapped in a `PREFLIGHT_TIMEOUT_MS` timeout. If it does not return `OK` in 30 seconds, stop and surface the
error. A model-resolution throw here means every candidate model for the tier is unavailable on the current
auth — the error lists what IS selectable; update the pins.

### Step 3 — Round N loop

For each round N:
1. Announce round start in chat with model.
2. Assemble the codex prompt using `references/codex-prompt-template.md` and the canonical dimension
   contract from `../../references/canonical-dimension-contract.md`.
3. Execute `scripts/invoke-codex-round.ps1` via Bash per the Execution model section
   (`pwsh -NoProfile -File <...>/invoke-codex-round.ps1 -ProjectPath <abs> -Round <N> -PromptPath <abs>
   -Model <tier model> -Tier <standard|complex> -ReasoningEffort <tier effort>`, wrapped in a `HANG_GUARD_MS`
   timeout) to run codex and write scratch `review-v<N>.md` plus scratch stream log atomically under
   `design\_review\`. The script pipes the prompt to codex over stdin and reports the actually-resolved
   model in its JSON output (`model` field) — announce that model, not just the requested pin.
4. Parse verdict via `scripts/parse-verdict.ps1 -FeedbackPath <review-v<N>.md> -Round <N>
   -StatePath <project>\design\_review\verdicts.json`. The script persists the parsed verdict and
   confidence for round N into `verdicts.json` (one entry per round, replace-on-rerun).
5. Reconcile each finding (ACCEPT / REJECT / DEFER / COUNTER), appending a `## Claude Response`
   section to the same scratch `review-v<N>.md` artifact. Then record each finding's disposition in
   round N's `findings` array in `verdicts.json`: `{ "finding": "<short stable title>",
   "disposition": "ACCEPT|REJECT|DEFER|COUNTER", "note": "<one line>" }`.
6. Re-raise detection is deterministic, never from conversation memory: before reconciling round N,
   read `verdicts.json` and diff round N's findings against round N-1's recorded dispositions. If a
   finding REJECTed in round N-1 is raised again in round N, pause and ask Danny using A/B/C
   adjudication:
   - A = accept Codex's point now
   - B = keep rejection with new rationale
   - C = defer to open question
7. Write scratch `draft-v<N+1>.md` only when termination rules indicate continuation or one final polish
   pass. This is a scratch working draft, not a design document — no round ever emits a retained design
   artifact.

### Step 4 — Output-shape obligations (Phase 4 addition)

All retained final outputs use `shape_version: 1` frontmatter per `references/design-shape.md`.

`design-final-<slug>.md` is the accepted design body only. Do not copy round-by-round archaeology,
stream-log references, or review summaries into the retained final artifact.

### Step 5 — Finalization

Run the finalization workflow from `references/finalization.md`:
- derive the slug (2-4 kebab-case words from the plan/project name) and copy the accepted draft to
  `design-final-<slug>.md` — the ONLY point in the whole run where a design document is written
- reconcile `CONTEXT.md` glossary against `design-final-<slug>.md`
- delete `design\_review\` scratch state after successful finalization via the explicit scripted
  cleanup step in `references/finalization.md` (run the command, then confirm the folder is gone)
- list retained output paths as bare absolute paths

## Deterministic scripts

This skill uses extracted deterministic scripts:
- `scripts/preflight-codex.ps1`
- `scripts/invoke-codex-round.ps1`
- `scripts/parse-verdict.ps1`
- `scripts/capture-provenance.ps1`

All external-text prompt assembly goes through repo-level `scripts/wrap-prompt-envelope.ps1`.
All stream/log redaction goes through repo-level `scripts/security/redact-secrets.ps1`.
All Codex model selection goes through repo-level `scripts/resolve-codex-model.ps1` (self-healing pin
resolution against the live model cache, shared with `dt-build`).

## Guardrails

- Do not edit scratch `draft-v<N>.md` after codex reviews it; only write a new version.
- Use `--sandbox read-only` for codex rounds; no codebase writes from codex in this skill.
- Keep round-state reconstructible only while the review is active; do not preserve scratch review
  artifacts after a successful freeze unless Danny explicitly asks.
- Verdict parsing is line-contract based (`VERDICT:` + `Confidence:`), not heading-based.
- If feedback is malformed during recovery, archive to `.partial.<timestamp>.md` and re-run round invoke.
- Keep SKILL.md under 5,000 words; long procedural detail belongs in `references/` and scripts.
