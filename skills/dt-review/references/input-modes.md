# Input Modes and Round 0

## Mode A - plan path

1. Read the supplied Markdown end to end.
2. Infer project and workstation from the path when the routing map makes them unambiguous.
3. Validate `shape_version` and required sections against repo-level `references/plan-shape.md`.
   Missing sections or an unknown major version are genuine user decisions; do not silently adapt.
4. Copy the source verbatim to `design\_review\draft-v1.md`.

## Mode B - substantive brief

Treat the trigger prompt as the plan and write it verbatim to `design\_review\draft-v1.md`. Add
`shape_version: 1` and the minimum plan-shape sections only when they are missing; do not invent
decisions.

## Mode C - interactive drafting

Use only when neither a plan nor a substantive brief exists. Gather the smallest missing set of
objectives, scope, constraints, architecture choices, and open questions, then write `draft-v1.md`.

## Tier and model selection

Infer rather than routinely asking:

- `light`: bounded component or contract with limited blast radius; cap 3.
- `complex`: cross-system, security-sensitive, production-critical, or hard-to-reverse design; cap 6.

Use the pinned model for the inferred tier. Ask only when the scope truly straddles tiers or Danny
explicitly requests a model choice. Pipeline/subagent invocation is noninteractive unless a genuine
fork appears.

## Evidence map

For a code-backed design or a design with current external/data assumptions, inspect the actual
code/data/docs once before Round 1 and write `design\_review\review-context.md`:

```markdown
# Review context

## Canonical constraints
- <absolute path + SHA256 + relevant rule>

## Build-intake revalidation
| Claim | Evidence/source | Checked at | Recheck gate |
| --- | --- | --- | --- |
```

Use file/symbol or query evidence. Mark anything not directly checked as `UNVERIFIED`. The final
design carries the `Build-intake revalidation` table so `dt-build` can recheck named assumptions.
