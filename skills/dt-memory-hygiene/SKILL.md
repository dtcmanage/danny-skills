---
name: dt-memory-hygiene
description: "Periodic maintenance pass for CLAUDE.md, MEMORY.md, CONTEXT.md, and glossary.md. Runs when deterministic bloat thresholds are exceeded. Compacts verbose entries, removes duplicate drift, normalizes shape, and preserves current-state clarity without changing underlying decisions."
metadata:
  version: 0.3.0
---

# Memory Hygiene

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

## HTML Review Artifact Requirement

For any artifact this skill produces for Danny to review, generate an HTML companion per `../../references/html-artifact-policy.md`.

Baseline requirement:
- Keep the primary machine/edit artifact (for example `.md`, `.json`, `.csv`) when needed.
- Also emit a review-first `.html` artifact in the same artifact family/folder.
- Include visual structure (cards/tables) plus at least one flow/state visualization (Mermaid or SVG).
- Report both output paths in the final skill output.

Do NOT generate the HTML companion automatically. Build it only when Danny explicitly asks. The render harness stays available; skipping it is the default.



This skill is a maintenance pass, not a session-capture pass.

- `dt-session-audit` captures new learnings quickly.
- `dt-memory-hygiene` trims accumulated memory debt.

Use this skill when:

1. `skills/dt-memory-hygiene/scripts/detect-memory-bloat.ps1` returns `should_run_hygiene=true`.
2. A file is hard to scan because entries are long, duplicated, or stale.
3. You are preparing for a major handoff/release and want compact memory quality.

## Deterministic Trigger Contract

Run the detector first from workspace root:

```powershell
pwsh -File skills/dt-memory-hygiene/scripts/detect-memory-bloat.ps1
```

Trigger hygiene automatically when any file hits:

- `token_est` over file-type threshold, OR
- `word_count` over `word_max` (CLAUDE.md files only — the detector's `word_count` is the single deterministic measurement of a CLAUDE.md word ceiling; never eyeball-count), OR
- `long_lines` over threshold, OR
- `duplicate_ratio` over threshold, OR
- `avg_bullet_words` over threshold with enough bullets, OR
- `bloat_score >= 3`.

If none hit, exit with a compact "no hygiene needed" summary.

## Scope

Target files:

- `CLAUDE.md`
- `MEMORY.md`
- `CONTEXT.md`
- `glossary.md`

Do not touch product code. Do not rewrite user intent.

## What Hygiene Changes

1. **Compress run-on entries** to current-state snapshots.
2. **Deduplicate overlapping bullets** in the same scope/file.
3. **Normalize shape** for project entries in MEMORY.md.
4. **Prune stale completion trails** that no longer help future sessions.
5. **Preserve meaning**: no policy reversals, no silent decision changes.

## Residency Sweep (CLAUDE.md files, advisory)

When a hygiene pass touches a `CLAUDE.md` file, additionally re-test every resident rule in it
against dt-session-audit's Residency Test: `CLAUDE.md` is a router, not a rulebook — a rule stays
resident only when no recognizable trigger exists (a task boundary, a phrase Danny says, a tool
about to be used) at which a session would open a reference file and find it.

For each rule that fails the test today (a trigger exists, and an owning reference file exists or
is cheap to create), surface a **relocation candidate**: the rule, its proposed destination
reference file, and the `References` trigger row to add or tighten — phrased in the words Danny
actually says. Existing References pointer rows are the router working as intended; never flag them.

This sweep is advisory and fires once per new candidate — never a blocking gate:

- Apply a relocation only on Danny's approval. Relocation moves the full rule text into the owning
  reference file and leaves no summary behind; the rule lives in exactly one file.
- When Danny declines a candidate, append an HTML comment marker on the rule's line in that
  `CLAUDE.md` — `<!-- residency:keep YYYY-MM-DD -->` — and never flag that rule again. A marked
  rule is skipped by every future sweep; the marker is the no-re-nag ledger and travels with the
  rule.
- If a candidate's destination file does not exist, propose creating it under the owning Resources
  folder; never relocate into a file you have not confirmed exists or just created.

## Safety Rules

1. Always read full target file before edits.
2. Preserve scope boundaries (root/workstation/project).
3. If conflict is semantic (not formatting), do not auto-resolve; surface it.
4. Keep sensitive data redacted or generalized.
5. After edits, output exactly what changed and why.

## Verification (mandatory)

After the hygiene edits, re-run the detector on the same targets:

```powershell
pwsh -File skills/dt-memory-hygiene/scripts/detect-memory-bloat.ps1
```

Include the before/after detector metrics for every touched file in the report (`token_est`, `long_lines`, `duplicate_ratio`, `avg_bullet_words`, `bloat_score`). A pass that does not improve the failing metric is not done — keep compacting, or surface exactly why that metric cannot move without a semantic change.

## Output

Produce:

1. A short before/after summary per touched file, including the before/after detector metrics from the verification re-run.
2. A "what was removed" list (duplicates, stale lines, excessive detail).
3. A residual-risk list for anything not safely auto-cleaned.
4. Only when Danny explicitly asks: a companion `memory-hygiene-report.html` with summary cards, change table, and risk/status visualization. Do NOT generate the HTML companion automatically; skipping it is the default.
5. Bare absolute paths for any written report artifacts.
