---
name: dt-memory-hygiene
description: "Periodic maintenance pass for CLAUDE.md, MEMORY.md, CONTEXT.md, and glossary.md. Runs when deterministic bloat thresholds are exceeded. Compacts verbose entries, removes duplicate drift, normalizes shape, and preserves current-state clarity without changing underlying decisions."
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

## Safety Rules

1. Always read full target file before edits.
2. Preserve scope boundaries (root/workstation/project).
3. If conflict is semantic (not formatting), do not auto-resolve; surface it.
4. Keep sensitive data redacted or generalized.
5. After edits, output exactly what changed and why.

## Output

Produce:

1. A short before/after summary per touched file.
2. A "what was removed" list (duplicates, stale lines, excessive detail).
3. A residual-risk list for anything not safely auto-cleaned.
4. A companion `memory-hygiene-report.html` with summary cards, change table, and risk/status visualization.
5. Bare absolute paths for any written report artifacts.
