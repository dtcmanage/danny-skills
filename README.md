# danny-skills

Claude Code skills authored for this workspace. Three of them form a single pipeline — scope a project, stress-test the design, then build it in parallel — and `dt-starter-session-audit` is a standalone end-of-session skill.

```
dt-design-build  →  dt-design-loop  →  dt-parallel-build
    (plan)            (critique)          (implement)
```

The three pipeline skills are self-contained and can be triggered on their own, but they're designed to compose: the output of one is the input of the next. `dt-starter-session-audit` runs independently at the end of any session.

---

## dt-design-build

**Trigger:** `/dt-design-build` or `dt-design-build <topic>`

A conversational planning partner — not a notetaker. Drives section-by-section discussion to produce a markdown plan file good enough that `dt-design-loop` can critique it without first cleaning up bad scaffolding.

**What it does:**

- Gathers project name, surface (CLI / service / integration / migration / UI / refactor / data pipeline), scope (light vs. complex), and save path in one combined question.
- Proposes a section structure tailored to the surface, then waits for confirmation before driving.
- Walks each section live: opens with a strawman rather than a blank prompt, pushes back where thinking is thin, surfaces absent concerns (no auth story? no rollback? no observability?), and parks unresolved items in a running Open Questions list.
- Saves a clean markdown plan (decisions only, no transcript) at the agreed path.

**Skip it for:** bug fixes, single-file changes, or anything where planning overhead exceeds savings.

---

## dt-design-loop

**Trigger:** `/dt-design-loop` or `dt-design-loop <plan-path>`

Adversarial Claude-vs-Codex dialogue on a plan. Two engineers debating the design as equals across multiple rounds until the design is genuinely shippable — or until the round cap forces a decision.

**What it does:**

- Reads the plan (from `dt-design-build`, a file path, or a substantive trigger prompt) into `draft-v1.md` verbatim. Plan structure is the author's call; the skill is structure-agnostic from Round 1 onward.
- Pre-flight: cheap sanity check that Codex responds, before burning reasoning tokens.
- Each round: Codex critiques the current draft (edge cases, security, robustness, consistency, engagement with prior reasoning) and emits a structured verdict (`NOTHING_TO_ADD` / `MINOR_POLISH_ONLY` / `MATERIAL_CHANGES_NEEDED`) + confidence.
- Claude reconciles per item — ACCEPT / REJECT / DEFER / COUNTER with real reasoning. Repeat-rejects (Codex raises, Claude rejects, Codex raises again) pause for the user to adjudicate.
- All artifacts (prompts, feedback, responses, drafts) live in `design/` with SHA-256 provenance — every decision is reconstructible.
- Terminates on `NOTHING_TO_ADD`, polish convergence, or round cap (3 for light tier, 6 for complex). Outputs `design-final.md` and `design-summary.md`.

**Skip it for:** bug fixes, single-file changes, exploratory throwaway code.

---

## dt-parallel-build

**Trigger:** `/dt-parallel-build`

One foreman, two coding agents (Claude + Codex) each in their own git worktree, one merge agent. Semantic conflicts escalate. Built for implementation work that decomposes cleanly into 2–6 independent chunks.

**What it does:**

- **Phase 1 — Foreman decomposition.** Freezes shared contracts (`contracts.md` — types, endpoints, schema, migration order, generated paths) BEFORE decomposing. Splits the plan into chunks with explicit file lists, dependencies, and acceptance criteria in `build-manifest.md`. Initializes `build-state.md` as the live ground-truth view.
- **Phase 2 — Worktrees.** One `git worktree` per chunk under `../worktrees/<RUN_ID>-<chunk-slug>/`. Hard containment check blocks any worktree that escapes the expected scope.
- **Phase 3 — Parallel execution.** Launches all agents in a single message so they actually run concurrently. Each prompt embeds the contracts revision SHA-256; agents must echo it back. Post-completion scope check catches unexpected files and escalates via 3-option adjudication (accept / revert / abort).
- **Phase 4 — Merge integration.** A dedicated Claude merge agent integrates branches in dependency order. Conflicts are classified against a fixed decision table — mechanical (formatting / import order / trivial-merge) and lockfile (policy-driven) can auto-resolve; semantic and generated-code conflicts always escalate with a standardized bundle (repro diff, impacted tests, blast radius, A/B candidates, recommendation).
- **Phase 5 — Cleanup and handoff.** Archives every artifact into `build-log-<RUN_ID>.md`. Optional PR or merge-to-main.

**Resume:** Phase 0 reconciles `build-state.md` against actual git/worktree state if a prior run was interrupted.

**Safety boundaries:**
- Test commands never reach a shell as a string — they're tokenized into argv and shell-quoted per element. Control characters in input are hard-rejected.
- Codex runs `--sandbox workspace-write` (never elevated).
- Agents are forbidden from writing outside their worktree.
- The merge agent has auto-action authority only for the conflict decision table; everything else escalates.

**Skip it for:** single-file features, tightly-coupled work, anything under ~1 hour of agent time.

---

## dt-starter-session-audit

**Trigger:** `/dt-starter-session-audit`, or "audit this session" / "session audit" / "what did we miss" / "end of session check"

A scope-aware end-of-session audit. Scans the conversation for things stated but never written down, then routes each finding on two axes — content class and scope tier — to one exact destination, surfacing contradictions for adjudication instead of filing them silently. Nothing is saved without batch approval.

**What it does:**

- Discovers the workspace root and reads the CLAUDE.md / MEMORY.md / CONTEXT.md / glossary.md layers in play this session, and the workspace Routing Map (as scope-topology data) to enumerate workstation tiers.
- Scans the full conversation for five signal types: corrections, explicit preferences, decisions, project state changes, and newly pinned terminology.
- **Routes on two axes.** Axis A — content class: rules → CLAUDE.md, facts → MEMORY.md, terminology → CONTEXT.md (project) or glossary.md (workstation). Axis B — scope tier: the narrowest of root / workstation / project where the finding is fully true. A finding true in disjoint scopes is handled as MULTI_SCOPE with a presentation and atomic-apply contract.
- **Runs a fixed Execution pipeline** with provenance, persisted-file trust, and redaction (fallback-ladder) gates, so different runs persist the same memory. An undecidable call resolves to UNCERTAIN and is surfaced, never auto-filed.
- **Refines instead of duplicating.** A deterministic match order selects the entry to touch; exact duplicates are silently skipped, sharper-same-meaning findings refine in place, governed by content-class-specific refine tests.
- **Never auto-files a contradiction.** A finding that negates a broader-scope rule or fact is surfaced under "Conflicts" with a structured resolution — fix-root / exclusion / flagged override for rules, update / scoped-delta / keep-and-drop for facts, Keep / Replace / Split for terms. Root stays the single source of truth for rules.
- **Drops genuine one-offs.** Session-only findings are listed under "Not saving (one-off)" and deliberately not persisted.
- Presents findings grouped into Recommend / Your call / Conflicts / Not saving / Auto-handled, each with a one-line rationale, then writes only the approved changes.

**Skip it for:** sessions where nothing was corrected, decided, or newly shared — it reports a clean session rather than manufacture findings.

---

## Installing

Each skill lives in `skills/<skill-name>/SKILL.md`. To use them in Claude Code, copy or symlink the `skills/` subfolders into your user-level skills directory (`~/.agents/skills/` on this machine — note: not `~/.claude/skills/`).
