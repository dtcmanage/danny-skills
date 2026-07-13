# danny-skills

Claude Code skills authored for this workspace. The pipeline now includes a visualization pass and a conditional prototype pass between planning and adversarial review, and `dt-session-audit` is a standalone end-of-session skill.

```
dt-plan  →  dt-visualize-plan  →  dt-prototype*  →  dt-review  →  dt-build
 (plan)         (visualize)       (prototype)         (critique)        (build)

* conditional: only when behavior/UI questions need runnable validation
```

The pipeline skills are self-contained and can be triggered on their own, but they're designed to compose: the output of one is the input of the next. `dt-session-audit` runs independently at the end of any session.

## Shared Skill Policy

All skills now include a `Shared Policy Baseline` block that points to:

- `references/deterministic-reference-policy.md` for deterministic execution + reference-loading rules.
- `references/conventions.md` for SKILL.md-anchored path resolution (`never from pwd`).
- `references/html-artifact-policy.md` for HTML-first review artifact standards.
- `references/versioning-policy.md` for skill/plugin SemVer, newest-first changelogs, and the mandatory
  `scripts/verify-versioning-policy.ps1` release gate.

This keeps deterministic and referencing behavior consistent across the full skill pack while allowing tighter per-skill domain guardrails where needed.

---

## dt-plan

**Trigger:** `/dt-plan` or `dt-plan <topic>`

A conversational planning partner — not a notetaker. Drives section-by-section discussion to produce a markdown plan file good enough that `dt-review` can critique it without first cleaning up bad scaffolding.

**What it does:**

- Gathers project name, surface (CLI / service / integration / migration / UI / refactor / data pipeline), scope (light vs. complex), and save path in one combined question.
- Proposes a section structure tailored to the surface, then waits for confirmation before driving.
- Walks each section live: opens with a strawman rather than a blank prompt, pushes back where thinking is thin, surfaces absent concerns (no auth story? no rollback? no observability?), and parks unresolved items in a running Open Questions list.
- Saves a clean markdown plan (decisions only, no transcript) at the agreed path.

**Skip it for:** bug fixes, single-file changes, or anything where planning overhead exceeds savings.

---

## dt-visualize-plan

**Trigger:** `/dt-visualize-plan` or `dt-visualize-plan <plan-path>`

Renders a saved plan into `plan-view.html` so structure and sequencing issues are obvious before adversarial review.

**What it does:**

- Supports three modes: `milestone-table-only`, `plan-plus-mermaid`, `ui-mockup`.
- Builds a single local HTML artifact (no dev server) with summary cards, milestone table, open questions, and plan preview.
- In mermaid modes, renders dependency graph + Gantt with local vendored mermaid (`assets/visualize/vendored/mermaid-10.9.3.min.js`) and `securityLevel: 'strict'`.
- Runs redaction (`scripts/security/redact-secrets.ps1`) before rendering injected content.
- Adds a dependency-provenance footer with active renderer/assets and any fallback debt tags.

**Skip it for:** adversarial review (`dt-review`) or implementation (`dt-build`).

---

## dt-prototype

**Trigger:** `/dt-prototype` or `dt-prototype <question>`

A conditional prototype stage between planning and adversarial review. Use it when text alone cannot answer a behavior or UI question.

**What it does:**

- Routes to one of two branches:
  - `logic`: builds a one-command terminal TUI to exercise reducers/state machines/policy logic.
  - `ui`: builds multiple radically different UI variants switchable from one route.
- Adapts Matt Pocock's prototype pattern with local vendored references and templates.
- Uses vendored starter templates in `skills/dt-prototype/assets/` for TypeScript/Python logic prototypes and a React variant switcher.
- Captures the result in `NOTES.md` next to the prototype, then expects cleanup (delete throwaway shells once decision is absorbed).

**Skip it for:** final production implementation, adversarial critique (`dt-review`), or build execution (`dt-build`).

---

## dt-review

**Trigger:** `/dt-review` or `dt-review <plan-path>`

Adversarial Claude-vs-Codex dialogue on a plan. Two engineers debating the design as equals across multiple rounds until the design is genuinely shippable — or until the round cap forces a decision.

**What it does:**

- Reads the plan (from `dt-plan`, a file path, or a substantive trigger prompt), validates/normalizes its Round 0 shape, then treats the resulting `draft-v1.md` as the immutable review input.
- Preflight verifies current CLI capabilities/auth on GPT-5.6 Luna before spending review tokens.
- Light reviews use GPT-5.6 Terra; complex reviews use GPT-5.6 Sol. Every review round pins medium reasoning rather than inheriting the user's global effort.
- Each round uses a JSON schema with stable finding IDs, prior-commitment checks, and a separate `blocks_design` materiality axis; scripts reject inconsistent verdicts.
- Claude reconciles each finding as ACCEPT / REJECT / DEFER / COUNTER against canonical constraints and evidence. Reopened rejections pause for user adjudication.
- Scratch prompts, reviews, streams, dispositions, and drafts live in `design/_review/` only while active. Successful finalization deletes them.
- Terminates immediately on `NOTHING_TO_ADD`, after polish convergence, or at a decision gate (3 light / 6 complex). Outputs only `design/design-final-<slug>.md`; a material last verdict can never finalize silently.

**Skip it for:** bug fixes, single-file changes, exploratory throwaway code.

---

## dt-build

**Trigger:** `/dt-build` or `dt-build <plan-path>`

Owns the whole build. Takes a finalized plan and delivers it on a short-lived `build/<RUN_ID>` branch cut from `main` — complete to spec, verified, committed milestone by milestone. One orchestrator decomposes the plan and drives a roster of build / verification / merge subagents across Claude and Codex; it never writes product code itself. Parallelism is one tactic, reached for only when the work genuinely splits — not a precondition.

**What it does:**

- **Scales to the plan.** No minimum-chunk gate: an easy plan runs as one milestone on one build subagent; a sprawling plan becomes many sequential milestones, several fanned out into parallel chunks across worktrees.
- **Milestone model.** A build is an ordered sequence of milestones — each a coherent, independently verifiable, independently committable slice, committed once verification passes. Milestones run sequentially; chunks within a milestone run in parallel.
- **One authoritative spec.** Phase 1 extracts a Decision Ledger and runs a mandatory preflight (repo state, dirty-tree isolation, a secret-bearing denylist scan, baseline-floor discovery, a two-level toolchain probe). Phase 2 writes an immutable `build-plan.md` with a unified verification manifest and takes a single explicit approval. Mid-build plan defects become numbered amendments; everything targets the resulting effective spec.
- **Verify-and-patch.** Every milestone is verified — machine-checkable or by a Claude verification subagent — before commit. Off-spec code is patched by a fresh fix subagent within a hard 2-attempt budget; plan defects escalate instead.
- **`main` is never the surface a failure lands on.** Phase 4 reruns integrated verification, rehearses the merge on the `build/<RUN_ID>` branch cut from the latest `main`, then updates that integration branch under a compare-and-swap.

**Resume:** Phase 0 reattaches to the run-specific branch and continues from the first uncommitted milestone — a committed milestone is a git commit.

**Safety boundaries:**
- Sandbox / model-routing / fix-budget are orchestrator-set and never derivable from artifact content.
- A secret-bearing denylist keeps secret files from reaching an external model provider; subagent output is scrubbed for secret-shaped values at the moment of ingest.
- Codex runs `--sandbox workspace-write` (never elevated); worktree containment is a hard block.
- `dt-build` lands work on a `build/<RUN_ID>` branch cut from `main` and never writes to `main` itself; the final merge is a separate human-authorized `/git-merge-feature` step.

**Skip it for:** authoring or reviewing the plan (that's `dt-plan` / `dt-review`), or non-git projects.

---

## dt-app-launcher

**Trigger:** `/dt-app-launcher`, "create an app launcher", "make this standalone", or "add desktop/start menu shortcut"

Creates or repairs a deterministic Windows standalone launcher for a local app/dashboard.

**What it does:**

- Scaffolds hardened launcher files into the target repo:
  - `scripts\start-<slug>.ps1`
  - `scripts\stop-<slug>.ps1`
  - `scripts\create-<slug>-shortcut.ps1`
  - `scripts\node\serve-static-app.js`
  - `start-<slug>.bat`
  - `<slug>-launcher.json`
- Launches static HTML/dashboard apps through Edge `--app` mode, not through shell file association.
- Uses an isolated temp profile and disables sync, extensions, Edge onboarding, default-browser checks, and first-run prompts.
- Creates Desktop and Start Menu shortcuts that point directly at the hardened start script.
- Requires a smoke test that verifies `--app`, isolated `--user-data-dir`, `--disable-sync`, `--disable-extensions`, listener state, and cleanup.

**Skip it for:** VS Code terminal colors (`dt-terminal-format-profile`), normal frontend debugging, or remote production service launchers.

---

## dt-session-audit

**Trigger:** `/dt-session-audit`, or "audit this session" / "session audit" / "what did we miss" / "end of session check"

A scope-aware end-of-session audit. Scans the conversation for things stated but never written down, then routes each finding on two axes — content class and scope tier — to one exact destination. Deterministic non-conflict writes are applied automatically.

**What it does:**

- Discovers the workspace root and reads the CLAUDE.md / MEMORY.md / CONTEXT.md / glossary.md layers in play this session, and the workspace Routing Map (as scope-topology data) to enumerate workstation tiers.
- Scans the full conversation for five signal types: corrections, explicit preferences, decisions, project state changes, and newly pinned terminology.
- **Routes on two axes.** Axis A — content class: rules → CLAUDE.md, facts → MEMORY.md, terminology → CONTEXT.md (project) or glossary.md (workstation). Axis B — scope tier: the narrowest of root / workstation / project where the finding is fully true. A finding true in disjoint scopes is handled as MULTI_SCOPE with a presentation and atomic-apply contract.
- **Runs a fixed Execution pipeline** with provenance, persisted-file trust, and redaction (fallback-ladder) gates, so different runs persist the same memory. An undecidable call resolves to UNCERTAIN and is surfaced, never auto-filed.
- **Refines instead of duplicating.** A deterministic match order selects the entry to touch; exact duplicates are silently skipped, sharper-same-meaning findings refine in place, governed by content-class-specific refine tests.
- **Never auto-files a contradiction.** A finding that negates a broader-scope rule or fact is surfaced under "Conflicts" with a structured resolution — fix-root / exclusion / flagged override for rules, update / scoped-delta / keep-and-drop for facts, Keep / Replace / Split for terms. Root stays the single source of truth for rules.
- **Drops genuine one-offs.** Session-only findings are listed under "Not saving (one-off)" and deliberately not persisted.
- Runs in autonomous mode: applies deterministic non-conflict updates without waiting for approval.
- Escalates only conflict/uncertain/ambiguous cases under "Your call" or "Conflicts".
- Runs deterministic bloat detection after writes; if tripped, automatically invokes `dt-memory-hygiene`.

**Skip it for:** sessions where nothing was corrected, decided, or newly shared — it reports a clean session rather than manufacture findings.

---

## dt-memory-hygiene

**Trigger:** auto-invoked by `dt-session-audit` when bloat is detected, or manual `/dt-memory-hygiene`

A periodic cleanup pass for memory/governance files (`CLAUDE.md`, `MEMORY.md`, `CONTEXT.md`, `glossary.md`) that trims bloat without changing policy intent.

**What it does:**

- Uses `skills/dt-memory-hygiene/scripts/detect-memory-bloat.ps1` to score bloat deterministically.
- Triggers on explicit thresholds (token size, long-line count, duplicate ratio, bullet density, or composite score).
- Compacts run-on entries, removes duplicate drift, and normalizes memory shape for fast future loading.
- Preserves scope boundaries and escalates semantic conflicts instead of silently rewriting intent.

**Skip it for:** normal small sessions where the detector says `should_run_hygiene=false`.

---

## Installing

Each skill lives in `skills/<skill-name>/SKILL.md`. To use them in Claude Code, copy or symlink the `skills/` subfolders into your user-level skills directory (`~/.agents/skills/` on this machine — note: not `~/.claude/skills/`).
