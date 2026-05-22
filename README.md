# danny-skills

Claude Code skills authored for this workspace. Three of them form a single pipeline — scope a project, stress-test the design, then build it — and `dt-starter-session-audit` is a standalone end-of-session skill.

```
dt-plan  →  dt-design-loop  →  dt-build
 (plan)        (critique)        (build)
```

The three pipeline skills are self-contained and can be triggered on their own, but they're designed to compose: the output of one is the input of the next. `dt-starter-session-audit` runs independently at the end of any session.

---

## dt-plan

**Trigger:** `/dt-plan` or `dt-plan <topic>`

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

- Reads the plan (from `dt-plan`, a file path, or a substantive trigger prompt) into `draft-v1.md` verbatim. Plan structure is the author's call; the skill is structure-agnostic from Round 1 onward.
- Pre-flight: cheap sanity check that Codex responds, before burning reasoning tokens.
- Each round: Codex critiques the current draft (edge cases, security, robustness, consistency, engagement with prior reasoning) and emits a structured verdict (`NOTHING_TO_ADD` / `MINOR_POLISH_ONLY` / `MATERIAL_CHANGES_NEEDED`) + confidence.
- Claude reconciles per item — ACCEPT / REJECT / DEFER / COUNTER with real reasoning. Repeat-rejects (Codex raises, Claude rejects, Codex raises again) pause for the user to adjudicate.
- All artifacts (prompts, feedback, responses, drafts) live in `design/` with SHA-256 provenance — every decision is reconstructible.
- Terminates on `NOTHING_TO_ADD`, polish convergence, or round cap (3 for light tier, 6 for complex). Outputs `design-final.md` and `design-summary.md`.

**Skip it for:** bug fixes, single-file changes, exploratory throwaway code.

---

## dt-build

**Trigger:** `/dt-build` or `dt-build <plan-path>`

Owns the whole build. Takes a finalized plan and delivers it on `dev` — complete to spec, verified, committed milestone by milestone. One orchestrator decomposes the plan and drives a roster of build / verification / merge subagents across Claude and Codex; it never writes product code itself. Parallelism is one tactic, reached for only when the work genuinely splits — not a precondition.

**What it does:**

- **Scales to the plan.** No minimum-chunk gate: an easy plan runs as one milestone on one build subagent; a sprawling plan becomes many sequential milestones, several fanned out into parallel chunks across worktrees.
- **Milestone model.** A build is an ordered sequence of milestones — each a coherent, independently verifiable, independently committable slice, committed once verification passes. Milestones run sequentially; chunks within a milestone run in parallel.
- **One authoritative spec.** Phase 1 extracts a Decision Ledger and runs a mandatory preflight (repo state, dirty-tree isolation, a secret-bearing denylist scan, baseline-floor discovery, a two-level toolchain probe). Phase 2 writes an immutable `build-plan.md` with a unified verification manifest and takes a single explicit approval. Mid-build plan defects become numbered amendments; everything targets the resulting effective spec.
- **Verify-and-patch.** Every milestone is verified — machine-checkable or by a Claude verification subagent — before commit. Off-spec code is patched by a fresh fix subagent within a hard 2-attempt budget; plan defects escalate instead.
- **`dev` is never the surface a failure lands on.** Phase 4 reruns integrated verification, rehearses the merge on a branch cut from the latest `dev`, then updates `dev` under a compare-and-swap.

**Resume:** Phase 0 reattaches to the run-specific branch and continues from the first uncommitted milestone — a committed milestone is a git commit.

**Safety boundaries:**
- Sandbox / model-routing / fix-budget are orchestrator-set and never derivable from artifact content.
- A secret-bearing denylist keeps secret files from reaching an external model provider; subagent output is scrubbed for secret-shaped values at the moment of ingest.
- Codex runs `--sandbox workspace-write` (never elevated); worktree containment is a hard block.
- `dt-build` lands work on `dev` and never touches `main`.

**Skip it for:** authoring or reviewing the plan (that's `dt-plan` / `dt-design-loop`), or non-git projects.

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
