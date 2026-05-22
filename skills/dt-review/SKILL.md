---
name: dt-review
description: "Adversarial Claude-vs-Codex design dialogue on a plan. Trigger on /dt-review or 'dt-review <plan-path>'. Do NOT use for small bug fixes or single-file edits."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(codex:*) Bash(git:*) Bash(pwsh:*) Read Write Edit AskUserQuestion"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.0.0
  changelog: "Initial Anthropic-standard Phase 4 release; renamed from dt-design-loop. CDC block pointer-swapped to repo-level canonical contract; input modes/prompt template/recovery/finalization extracted to references; deterministic round scripts added with shared prompt-envelope and redaction primitives."
---

# Review — Claude x Codex Coworker Dialogue

`dt-review` is adversarial design critique for a plan. Two engineers debate the design as equals across
rounds until it converges or the cap is reached.

The output is a traceable design artifact set under `design/`:
- `draft-v<N>.md`
- `codex-feedback-v<N>.md`
- `claude-response-v<N>.md`
- `design-final.md`
- `design-summary.md`

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

Use these constants unless Danny explicitly overrides:
- `LIGHT_MODEL = gpt-5.3-codex`
- `COMPLEX_MODEL = gpt-5.4`
- `PREFLIGHT_MODEL = gpt-5.3-codex`
- `PREFLIGHT_TIMEOUT_MS = 30000`
- `HANG_GUARD_MS = 1800000`

## Canonical contracts and references

Read these files on demand from this skill folder and repo root:
- `references/input-modes.md` — intake and Round 0 mode selection (A/B/C).
- `references/codex-prompt-template.md` — codex critique template and required verdict format.
- `references/recovery.md` — interrupted-round resume rules and malformed feedback handling.
- `references/finalization.md` — finalization, glossary reconciliation, promotion-gate workflow.
- `references/design-shape.md` — `shape_version` policy + output schema for `design-final.md` and `design-summary.md`.
- `../../references/canonical-dimension-contract.md` — single canonical Dimension Contract source.

Never inline-copy the Canonical Dimension Contract into this SKILL.md. Pointer-swap is mandatory.

## Procedure

### Step 1 — Combined intake

Run one `AskUserQuestion` that captures:
- Project name (when not inferable from a provided plan path)
- Workstation (when not inferable)
- Tier (`light` or `complex`)
- Optional model override

Then apply Mode A/B/C from `references/input-modes.md` and write `draft-v1.md` verbatim from the selected
source, only appending `## Dialogue Log` if absent.

### Step 2 — Pre-flight

Run `scripts/preflight-codex.ps1` before Round 1. If it does not return `OK` in 30 seconds, stop and
surface the error.

### Step 3 — Round N loop

For each round N:
1. Announce round start in chat with model + stream-log path.
2. Assemble the codex prompt using `references/codex-prompt-template.md` and the canonical dimension
   contract from `../../references/canonical-dimension-contract.md`.
3. Execute `scripts/invoke-codex-round.ps1` to run codex, capture stream log, and write
   `codex-feedback-v<N>.md` atomically.
4. Parse verdict via `scripts/parse-verdict.ps1`.
5. Reconcile each finding (ACCEPT / REJECT / DEFER / COUNTER), writing `claude-response-v<N>.md`.
6. If a previously REJECTed finding is raised again in the immediately following round, pause and ask Danny
   using A/B/C adjudication:
   - A = accept Codex's point now
   - B = keep rejection with new rationale
   - C = defer to open question
7. Write `draft-v<N+1>.md` only when termination rules indicate continuation or one final polish pass.

### Step 4 — Output-shape obligations (Phase 4 addition)

All final outputs use `shape_version: 1` frontmatter per `references/design-shape.md`.

`design-summary.md` must include an `Ambiguity Closures` section. For each finding flagged
`AMBIGUOUS_ROOT_CAUSE`, write a closure block with required fields:
- `finding_id`
- `candidate_dimensions`
- `missing_evidence`
- `temporary_primary`
- `closure_status` (`closed` or `carry_forward`)
- `owner` (default `Danny`)
- `closure_date_or_next_review`

### Step 5 — Finalization

Run the finalization workflow from `references/finalization.md`:
- copy accepted draft to `design-final.md`
- reconcile `CONTEXT.md` glossary against `design-final.md`
- write `design-summary.md`
- list output paths as bare absolute paths

## Deterministic scripts

This skill uses extracted deterministic scripts:
- `scripts/preflight-codex.ps1`
- `scripts/invoke-codex-round.ps1`
- `scripts/parse-verdict.ps1`
- `scripts/capture-provenance.ps1`

All external-text prompt assembly goes through repo-level `scripts/wrap-prompt-envelope.ps1`.
All stream/log redaction goes through repo-level `scripts/security/redact-secrets.ps1`.

## Guardrails

- Do not edit `draft-v<N>.md` after codex reviews it; only write a new version.
- Use `--sandbox read-only` for codex rounds; no codebase writes from codex in this skill.
- Keep every decision reconstructible from prompt, feedback, response, and Dialogue Log artifacts.
- Verdict parsing is line-contract based (`VERDICT:` + `Confidence:`), not heading-based.
- If feedback is malformed during recovery, archive to `.partial.<timestamp>.md` and re-run round invoke.
- Keep SKILL.md under 5,000 words; long procedural detail belongs in `references/` and scripts.
