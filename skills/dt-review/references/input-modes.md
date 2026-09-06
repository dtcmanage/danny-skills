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

## Tier, lane, and model selection

Infer rather than routinely asking:

- `light`: bounded component or contract with limited blast radius; cap 3.
- `complex`: cross-system, security-sensitive, production-critical, or hard-to-reverse design; cap 4.

Production-critical means a wrong design costs money, data, or an external relationship; a personal
tool that happens to run on the production VM is `light`.

Record the draft's primary author family at Round 0 and fix the reviewer lane to the opposite family
(Claude-authored -> Codex lane; Codex-authored -> Claude lane; mixed/unclear -> Codex lane). Tier and
lane are both immutable for the review.

Use the pinned model for the inferred tier and lane. Ask only when the scope truly straddles tiers or
Danny explicitly requests a model choice. Pipeline/subagent invocation is noninteractive unless a
genuine fork appears.

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

Once `review-context.md` exists, `finalize-review.ps1` **refuses** a final design without a section headed
exactly `## Build-intake revalidation` — and by finalization the reviewed draft is hash-bound, so the
omission cannot be repaired in flow. Carry the table into the draft itself, not only into
`review-context.md`. `assemble-review-prompt.ps1` enforces this as a **hard gate at Round 1**
(`BUILD_INTAKE_GATE`): a `draft-v1.md` without the section cannot start the review. For an evidence map
created mid-review (Round 2+), the assembler warns every round while this is still fixable, emitting
`build_intake_warning` in its JSON; treat that warning as work to do before authoring the next draft.
