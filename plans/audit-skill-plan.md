# dt-session-audit Enhancement — Build Plan
**Date:** 2026-05-17
**Surface:** Claude Code skill authoring (enhancement to an existing skill)
**Scope:** complex
**Repo:** dtcmanage/danny-skills
**Target:** `skills/dt-session-audit/SKILL.md`

## Goal

Extend `dt-session-audit` from a two-file router into a scope-aware,
three-file router that also catches terminology and never lets a session
silently contradict a broader-scope rule.

Today the skill scans four signal types and routes each finding to one of two
files by a single test (prescribes behavior -> `CLAUDE.md`; fact -> `MEMORY.md`).
It has no notion of *which tier* a finding belongs to, no terminology handling,
and no defense against a narrow-scope finding quietly overriding a root rule.

This enhancement adds five things:

1. A **second routing axis** — scope tier (root -> workstation -> project) — on
   top of the existing file-type axis.
2. A **third file target** — `CONTEXT.md` for terminology — wired to reuse the
   glossary-workflow contracts already shipped in `design-build` / `design-loop` /
   `parallel-build` (commit `4d45d2c`, v0.2.3).
3. **Edit-and-refine + silent-skip** — exact duplicates are dropped silently;
   sharper-but-same-meaning findings edit the existing entry in place rather than
   appending a second one.
4. A **conflict policy** — a finding that contradicts a broader-scope rule is
   never auto-filed; it is surfaced for explicit adjudication, and the root stays
   the single source of truth.
5. An explicit **DROP outcome** — session-only one-offs are recognized and
   deliberately not persisted.

The implementation surface is one file (`SKILL.md`) plus manifest and README
touch-ups. It is marked `complex` for `design-loop` because the *design* surface
— two interacting axes, two conflict mechanisms, cross-skill consistency —
warrants the deeper round cap, not because the code change is large.

## Current State (what the skill does today)

The skill runs end-of-session in six steps:

- **Step 1 — Discover workspace.** Reads root `CLAUDE.md` / `MEMORY.md`, plus any
  workstation and project `CLAUDE.md` / `MEMORY.md` used that session.
- **Step 2 — Scan.** Four signal types: corrections, explicit preferences,
  decisions, project state changes.
- **Step 3 — Filter against what is already saved.** Skips anything already
  written; for project state, checks whether the existing entry is still accurate.
- **Step 4 — Decide file and shape.** A single two-test rule: prescribes
  behavior -> `CLAUDE.md`; changeable fact -> `MEMORY.md`. `MEMORY.md` entries are
  revise-in-place / add / append-fact.
- **Step 5 — Present.** Findings grouped into "Recommend" and "Your call".
- **Step 6 — Apply.** Writes only approved changes.

The core principle — `MEMORY.md` is a tight canonical snapshot, not a changelog;
project entries are revised in place — is sound and is **preserved unchanged** by
this enhancement.

The gaps this plan closes: Step 1 already *reads* workstation/project files but
Step 4 routing ignores the tier; there is no terminology target; and nothing
stops a narrow-scope finding from quietly overriding a broader rule.

## Change 1 — Routing becomes two axes

### Axis A — file type (was two targets, now three)

- **CLAUDE.md** — instructions / rules. A finding that *prescribes behavior*
  ("always", "never", "before X do Y"). Unchanged in meaning.
- **MEMORY.md** — facts / context that can change (status, paths, IDs, contacts,
  decisions). Unchanged.
- **CONTEXT.md** — pinned terminology. **New.** A finding that *defines,
  disambiguates, or splits a term*. Requires a fifth scan signal (Change 5).

### Axis B — scope tier (new)

Every finding is placed at the **narrowest tier where it is fully true**:

- **root** — workspace-wide `CLAUDE.md` / `MEMORY.md`.
- **workstation** — a persistent middle tier: the workstation's `CLAUDE.md` /
  `MEMORY.md`.
- **project** — a single project's `CLAUDE.md` / `MEMORY.md`.

The test is mechanical: file at the lowest tier whose statement holds without
exception. If it holds everywhere, it is root. A finding is never filed at a tier
broader than the scope in which it is actually true.

### The combined decision

For each finding: (Axis A -> file) x (Axis B -> tier) -> one destination — OR one
of two non-write outcomes: **DROP** (Change 6) or **CONFLICT** (Change 4).

The axes are not fully independent: terminology (`CONTEXT.md`) has only **two**
tiers, not three — see Change 5 and Open Question 4.

## Change 2 — The workstation tier becomes first-class

Step 1 already reads workstation files, but Step 4 routing collapses everything
to root-vs-project by file type. This change makes workstation a real routing
destination on Axis B.

Workstation discovery reuses the **Routing Map in the workspace `CLAUDE.md`** —
the same map `design-build` reads to infer `<workstation>` from a project
description. The audit skill must not invent its own workstation-detection
mechanism; it reads the existing Routing Map and places findings against the
workstations that map identifies.

## Change 3 — Edit-and-refine + silent-skip

Step 3 today is a binary "skip if already written, else surface." Replace it with
four classifications applied to every finding against the entry it would touch:

- **Identical** — the finding is already captured verbatim-equivalent. **Silent
  skip** — not surfaced at all.
- **Sharper, same meaning** — the finding refines an existing entry without
  changing its meaning. **Edit in place.** "Same meaning" is the glossary
  workflow's wording-only test: the edit must preserve all four of scope,
  exclusions, actor / entity mapping, and the semantic class of any example. If
  any of the four changes, it is a meaning change -> CONFLICT.
- **Genuinely new** — no existing entry covers it. **Add.**
- **Contradicts** — see Change 4. **CONFLICT.**

This generalizes the existing `MEMORY.md` "revise in place" operation so it
applies to `CLAUDE.md` rules and `CONTEXT.md` terms as well. The `MEMORY.md`
snapshot principle and the per-entry project shape are unchanged.

## Change 4 — Conflict policy: contradictions never resolve silently

This is the core guardrail. It exists to stop the skill from eroding root intent
one rationalized "specialization" at a time.

### Specialization vs contradiction

- **Additive specialization** — the narrow-scope finding adds detail the broader
  entry does not speak to, *without making the broader entry false*. File it at
  the narrow tier, no conflict.
- **Contradiction** — the narrow-scope finding *negates, reverses, or makes the
  broader entry false within the narrower scope*. **CONFLICT** — never auto-filed.

The test is mechanical and the skill may not relabel a contradiction as
specialization to avoid the adjudication: if the finding makes a broader-scope
entry false anywhere, it is a contradiction, full stop.

### Resolving a CLAUDE.md rule conflict

Surface the conflict with exactly three resolutions:

- **(a) Fix root** — the new learning supersedes; amend the root rule itself.
- **(b) Exclusion at root** — the root rule stays, but root is edited to carve
  out the explicit exception ("do X — except in `<scope>` Y, do Z"). The
  exception lives *at root*.
- **(c) Flagged local override** — write the rule at the narrow tier with a
  visible deviation note, *and* a red-flag back at root pointing to it.

Invariant: **root stays the single source of truth** — every exception is either
in root or pointed to from root. No orphan contradictions at lower tiers.

A session-level finding may **never** override root. If a session finding
contradicts root it is either DROP (a one-off) or escalate-to-root (evidence root
is wrong) — it is never silently written at a narrow tier.

### Resolving a CONTEXT.md term conflict

Use the glossary workflow's existing handling **verbatim**: a wording-only edit
auto-applies; a meaning-changing conflict pauses with the structured three-option
`AskUserQuestion` — **(A) Keep**, **(B) Replace**, **(C) Split**. The rule-conflict
options and the term-conflict options are deliberately different option sets
today; whether to unify them is Open Question 2.

## Change 5 — The terminology pass (CONTEXT.md)

Add a fifth scan signal — **Terminology** — for session moments where a fuzzy or
overloaded term was pinned to a precise meaning, a new domain term was coined, or
two senses of one word were split apart.

The pass **reuses the shipped glossary-workflow contracts** — it must not
reinvent them:

- **Location contract** (from `design-loop`): project `CONTEXT.md` at the project
  folder root; workstation `glossary.md` at
  `<workstation>\<Workstation> Resources\glossary.md`.
- **Placement test** (from `design-build`): a term that means the same thing
  domain-wide -> workstation `glossary.md`; a term specific to one project ->
  that project's `CONTEXT.md`; the same word carrying two genuinely different
  meanings -> split.
- **Narrowing**: a project `CONTEXT.md` may narrow a workstation term as a
  pointer / delta entry that opens "Project-specific narrowing of workstation
  term `<Term>`" and states only the delta. Narrowing is *additive
  specialization* (Change 4), not a contradiction — the baseline stays in one
  place and the entry is explicitly flagged.
- **Split-term rule**: `<Term> (<qualifier>)` plus a cross-reference entry under
  the retired ambiguous label.
- **Conflict handling**: the two-stage wording-only / meaning-change filter
  above.
- **Promotion gate** (project -> workstation): all three of — appears in 2+
  durable artifacts, definition is implementation-agnostic, no project-specific
  qualifier required.
- **Entry format**: `Definition` / `Not to be confused with` / `Example`, with
  the `Example` field generic or anonymized — never a real LP name, account
  number, or counterparty identity.

Relationship to `design-build`: `design-build` pins terms *during* planning. The
audit catches terms pinned in *any* session that never made it into a file. Same
contracts, different trigger point — the audit is the retroactive safety net.

Terminology has only two tiers — workstation `glossary.md` and project
`CONTEXT.md`. The shipped glossary workflow has no root-level glossary; a
genuinely cross-workstation term has no home today (Open Question 4).

## Change 6 — The DROP outcome

A finding that is genuinely session-scoped — a one-off instruction that applied
only to this task, a decision that will not recur — is recognized and
**deliberately not written anywhere**.

DROP findings are listed compactly under a "Not saving (one-off)" group so Danny
can catch a misclassification, but the default action is no write. This keeps the
workspace files free of ephemera. Whether DROP should instead be fully silent is
Open Question 5.

## Step-by-step changes to SKILL.md

- **Step 1 — Discover.** Also locate `CONTEXT.md` / `glossary.md` per the
  Location contract; read the workspace Routing Map to enumerate workstation
  tiers.
- **Step 2 — Scan.** Add the fifth signal type, Terminology.
- **Step 3 — Filter -> Classify.** Replace the binary skip with the four
  classifications of Change 3, plus DROP.
- **Step 4 — Route.** Replace the single "two-test rule from CLAUDE.md" with the
  self-contained two-axis decision (file x tier), the placement test for
  terminology, and the contradiction check.
- **Step 5 — Present.** Groups become: Recommend / Your call / **Conflicts**
  (each with the structured three-option resolution) plus the compact "Not saving
  (one-off)" list.
- **Step 6 — Apply.** Apply approved changes; apply Danny's chosen conflict
  resolution; never silently override root.

## Integration with the glossary workflow

The audit skill must not duplicate-and-drift from `design-build` / `design-loop` /
`parallel-build`. Default approach: `SKILL.md` states the terminology contracts
by reference, naming `design-build` / `design-loop` as the authoritative source,
rather than re-deriving them. The pack already duplicates the glossary entry
format inline across `design-build` and `design-loop` ("identical to
`design-build`") — so some duplication is established practice. Whether to
extract a single shared contract file that all four skills read is Open
Question 1.

## Manifest & Versioning

- `plugin.json` and `.claude-plugin/marketplace.json`: bump `0.2.3 -> 0.2.4`
  (enhancement to an existing skill, pre-1.0). Convention is Open Question 6.
- Update the `dt-session-audit` description string in both manifests and in
  the `SKILL.md` frontmatter to reflect the third file (`CONTEXT.md`),
  terminology capture, and scope-aware routing. The current description hard-codes
  "CLAUDE.md and MEMORY.md in the root folder" — that becomes stale.
- Update the `dt-session-audit` section of `README.md` to describe the
  two-axis routing, the terminology pass, the conflict policy, and the DROP
  outcome.

## Acceptance Criteria

- `SKILL.md` scan covers five signal types, including Terminology.
- Routing is two-axis: file type (`CLAUDE.md` / `MEMORY.md` / `CONTEXT.md`) x
  tier (root / workstation / project), with workstation a first-class
  destination and the narrowest-true-tier test stated explicitly.
- Edit-and-refine and silent-skip are implemented; the wording-only vs
  meaning-change distinction (four preserved invariants) governs whether a
  refinement auto-applies.
- Contradictions are never auto-filed; rule conflicts surface the three-option
  resolution (fix root / exclusion at root / flagged local override); term
  conflicts use the glossary three-option handling (Keep / Replace / Split); a
  session finding never overrides root.
- The terminology pass reuses the glossary Location contract, placement test,
  narrowing rule, split-term rule, conflict handling, promotion gate, and entry
  format — consistent with the three glossary-workflow skills.
- DROP is an explicit outcome; one-offs are not written.
- The `MEMORY.md` snapshot principle and project-entry shape are preserved.
- Manifests bumped and description strings updated; README section updated.
- `SKILL.md` frontmatter is valid and matches the other skills' style.

## Open Questions

1. **Shared glossary contract vs inline duplication.** Extract the Location
   contract / placement test / entry format / conflict handling into one shared
   reference file that the audit skill and the three glossary skills all read, or
   keep duplicating inline (current pack practice)? Duplication risks drift as
   the contracts evolve.
2. **Two conflict mechanisms — unify or keep separate?** Rule conflicts use
   fix-root / exclusion-at-root / flagged-override; term conflicts use Keep /
   Replace / Split. Same underlying principle, different option sets. Keep both,
   or unify into one vocabulary?
3. **The additive-vs-contradiction boundary.** Is the "negates / reverses /
   makes-false-in-scope" test sharp enough to stop the skill rationalizing a
   contradiction as specialization? Gray case: a rule that *tightens* a broader
   rule for one scope — restriction (contradiction) or specialization (additive)?
   Note glossary "narrowing" is deliberately classed as additive; the rule side
   needs an equally crisp line.
4. **Root-tier terminology.** The shipped glossary workflow tops out at
   workstation `glossary.md` — no root glossary. Is a genuinely cross-workstation
   term simply out of scope, or does the workflow need a root-level glossary file?
5. **DROP visibility.** Show one-off findings under a compact "Not saving" list
   (safety net against misclassification) or drop them fully silently?
6. **Version bump convention.** `0.2.4` (patch) vs `0.3.0` (minor) for a
   capability-expanding change to one skill. Pre-1.0; pick one convention
   pack-wide — the `prototype` plan flagged the same question.
7. **Routing logic location.** Keep the two-axis routing fully self-contained in
   `SKILL.md`, or have it reference the workspace `CLAUDE.md` (as today's "two-test
   rule from CLAUDE.md" does)? Self-contained is more portable; the CLAUDE.md
   reference keeps a single source of truth for the workspace's own conventions.

## Out of Scope

- Changes to `design-build` / `design-loop` / `parallel-build` glossary handling
  — unless Open Question 1 is resolved in favor of extraction, which would touch
  all four skills.
- Auto-invocation or programmatic handoff between the audit skill and any other
  skill — all transitions stay Danny's call, consistent with the pack.
- Splitting the audit into multiple skills, or renaming it (the `starter-` prefix
  stays for now).
- Building a glossary from scratch unprompted — the audit only captures terms a
  session actually pinned; conversational glossary authoring remains
  `design-build`'s job.
- Non-terminology workspace cleanup or file reorganization — the skill stays an
  audit, not a refactor.

