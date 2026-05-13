# danny-skills

Three Claude Code skills that form a single pipeline: scope a project, stress-test the design, then build it in parallel.

```
design-build  →  design-loop  →  parallel-build
   (plan)         (critique)        (implement)
```

Each skill is self-contained and can be triggered on its own, but they're designed to compose. The output of one is the input of the next.

---

## design-build

**Trigger:** `/design-build` or `design-build <topic>`

A conversational planning partner — not a notetaker. Drives section-by-section discussion to produce a markdown plan file good enough that `design-loop` can critique it without first cleaning up bad scaffolding.

**What it does:**

- Gathers project name, surface (CLI / service / integration / migration / UI / refactor / data pipeline), scope (light vs. complex), and save path in one combined question.
- Proposes a section structure tailored to the surface, then waits for confirmation before driving.
- Walks each section live: opens with a strawman rather than a blank prompt, pushes back where thinking is thin, surfaces absent concerns (no auth story? no rollback? no observability?), and parks unresolved items in a running Open Questions list.
- Saves a clean markdown plan (decisions only, no transcript) at the agreed path.

**Skip it for:** bug fixes, single-file changes, or anything where planning overhead exceeds savings.

---

## design-loop

**Trigger:** `/design-loop` or `design-loop <plan-path>`

Adversarial Claude-vs-Codex dialogue on a plan. Two engineers debating the design as equals across multiple rounds until the design is genuinely shippable — or until the round cap forces a decision.

**What it does:**

- Reads the plan (from `design-build`, a file path, or a substantive trigger prompt) into `draft-v1.md` verbatim. Plan structure is the author's call; the skill is structure-agnostic from Round 1 onward.
- Pre-flight: cheap sanity check that Codex responds, before burning reasoning tokens.
- Each round: Codex critiques the current draft (edge cases, security, robustness, consistency, engagement with prior reasoning) and emits a structured verdict (`NOTHING_TO_ADD` / `MINOR_POLISH_ONLY` / `MATERIAL_CHANGES_NEEDED`) + confidence.
- Claude reconciles per item — ACCEPT / REJECT / DEFER / COUNTER with real reasoning. Repeat-rejects (Codex raises, Claude rejects, Codex raises again) pause for the user to adjudicate.
- All artifacts (prompts, feedback, responses, drafts) live in `design/` with SHA-256 provenance — every decision is reconstructible.
- Terminates on `NOTHING_TO_ADD`, polish convergence, or round cap (3 for light tier, 6 for complex). Outputs `design-final.md` and `design-summary.md`.

**Skip it for:** bug fixes, single-file changes, exploratory throwaway code.

---

## parallel-build

**Trigger:** `/parallel-build`

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

## Installing

Each skill lives in `skills/<skill-name>/SKILL.md`. To use them in Claude Code, copy or symlink the `skills/` subfolders into your user-level skills directory (`~/.agents/skills/` on this machine — note: not `~/.claude/skills/`).
