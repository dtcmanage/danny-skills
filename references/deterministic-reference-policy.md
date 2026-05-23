# Deterministic and Referencing Policy

Shared baseline policy for all skills in this repo. Skill-local logic still owns domain behavior, but these rules are always in effect unless a skill explicitly narrows them.

## Deterministic Execution Contract

1. Execute the skill's declared steps in order.
2. Do not skip or reorder required validation gates for convenience.
3. If a step cannot be justified mechanically from available evidence, stop that path and escalate (`UNCERTAIN` or equivalent skill-specific escalation).
4. When a skill ships deterministic scripts for a step, run those scripts instead of recreating the procedure ad hoc.
5. For multi-target writes, compute and validate all target edits first, then apply atomically where the skill contract requires all-or-none behavior.
6. After writes, report exactly what changed and what remains escalated.

## Reference Loading Contract

1. Resolve all paths from the calling `SKILL.md` location, never from `pwd`. Use `references/conventions.md` as canonical path-resolution guidance.
2. Treat referenced contracts/scripts as authoritative for their scoped behavior. Do not inline-copy large normative contracts into `SKILL.md` when a stable reference exists.
3. Load only the references needed for the current branch/task path.
4. If a required reference path is missing/unreadable, surface the exact path and stop that dependent branch instead of guessing.
5. Repository shared references are read-only by default during execution unless the task explicitly requests changing them.

## Conflict Handling

- Skill-local explicit rules win for domain behavior if they intentionally narrow this baseline.
- This baseline still governs path resolution, deterministic sequencing discipline, and reference authority unless a stricter local rule is stated.
