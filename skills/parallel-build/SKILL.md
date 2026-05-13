---
name: parallel-build
description: Parallel Claude+Codex build in git worktrees with a merge agent. Trigger on "/parallel-build".
---

# Parallel Build — Claude × Codex Coordinated Implementation

One foreman. Two coding agents (Claude + Codex), each in its own git worktree. One merge agent. Semantic conflicts escalate to Danny.

## When this fires

Trigger when ALL of these hold:
- There is a written plan or finalized design (typically from `design-loop`)
- The plan has at least 3 chunks that can be worked independently
- Total estimated effort > 1 hour of agent time (otherwise overhead exceeds savings)
- The repo is git-tracked

**Do NOT fire** for: single-file features, bug fixes, refactors that touch one module, or any work where the chunks have tight coupling. If chunks share state or interface contracts in ways that will cause merge pain, run sequentially instead.

## Run-level artifacts

Each parallel-build run produces and maintains four artifacts at the repo root for the duration of the run, then archives them at Phase 5:

- `build-manifest.md` — written once by the foreman in Phase 1. Chunk list, assignments, expected files, dependencies, briefs, acceptance criteria. **Immutable** after Phase 1 approval.
- `manifest-overrides.md` — append-only. Records scope-adjudication option-A approvals (where Danny accepts unexpected files into a chunk). Each override entry is timestamped and references the chunk-id; merge agent reads `manifest + overrides` deterministically.
- `contracts.md` — written once by the foreman in Phase 1, BEFORE decomposition. Shared interfaces, types, API endpoints, schemas, migration order, generated-path globs. Each agent prompt embeds the SHA-256 of contracts.md as `contracts_revision`; each agent must echo it back. Can be edited mid-run during scope adjudication if Danny approves; doing so invalidates in-flight agents against the old revision (caught at merge time by the revision-token check).
- `build-state.md` — initialized at the end of Phase 1, updated atomically after every phase transition for every chunk. The canonical "what is happening right now" view.

`build-state.md` schema (fixed format — no ad-hoc fields):

```markdown
# Build State — <project> — <RUN_ID>

## Chunks

| chunk-id | name | assignee | status | branch | commit-sha | start-ts | end-ts | canonical-worktree | unexpected-files | blocker |
|----------|------|----------|--------|--------|------------|----------|--------|--------------------|------------------|---------|

## Metadata

RUN_ID: <YYYYMMDD-HHMM>
BASE_REF: <branch-name>
repo_canonical_path: <path>
test_command: <verbatim input string from Danny — for audit only, never passed to shell>
test_command_argv: <JSON array, e.g. ["pytest", "-q", "--tb=short"]; empty [] when test_command_mode is skip>
test_command_mode: <run | skip>
test_command_confirmation: <none | unknown-runner | metachar-in-args | multiple>
test_command_reentry_count: <integer ≥ 0>
lockfile_policy: <confirm-with-Danny | auto-regenerate>
failed_worktree_retention: <ask-per-chunk | keep-all>
overlap_minutes: <N>
parallelism_detected: <yes | no | unknown>

## Per-chunk metadata

### <chunk-id>
contracts_revision_echoed: <hash | "pending">
scope_decision: <A | B | C | "none">
serialization_warning_fired: <yes | no>
```

**Status lifecycle:**

```
pending → running
running → {complete, blocked, unknown}
complete → merged
unknown → {running, complete, blocked}
```

`unknown` is written ONLY by Phase 0 Resume/Recover when the build-state row was `running` but no live agent process exists. `merged` is reachable only from `complete`. No other transitions are allowed.

**Per-chunk metadata key contract:**

| Key | Required after | Default if not yet set |
|---|---|---|
| `contracts_revision_echoed` | chunk reports complete in Phase 3 | `pending` |
| `scope_decision` | scope check yields option A/B/C | `none` |
| `serialization_warning_fired` | always present (initialized to `no` at Phase 1 step 1e) | `no` |

Consumers (Phase 0 recovery, merge agent stale-contracts check, build-log archiver) interpret defaults explicitly: `pending` means the agent has not yet reported back; `none` means the scope check has not yet run. No ambiguity between "missing" and "not yet evaluated."

Updates are atomic full-file rewrites via the `Write` tool (table + Metadata + Per-chunk metadata together) — this prevents partial-update corruption if the foreman is interrupted.

## Inputs to gather

Ask Danny in one combined `AskUserQuestion` call:
1. **Repo path** (absolute Windows path, e.g. `D:\Projects\TCMdashboard`)
2. **Plan source** (path to design doc, or "I'll paste it")
3. **Codex model** (default from config, or override)
4. **Test command** (e.g. `pytest -q`, `npm test`, `cargo test` — used by merge agent for integration check; enter the literal string `skip` if no test suite should run)
5. **Lockfile conflict policy** — when a lockfile conflict appears at merge: `confirm-with-Danny` (default) | `auto-regenerate` (run the project's standard lock command with safe-mode flags and verify)
6. **Failed-worktree retention** — when a chunk is blocked or abandoned: `ask-per-chunk` (default) | `keep-all` (always move failed worktrees to `../worktrees/failed/<chunk-id>` for postmortem)

### Test command validation

If Danny's input matches the literal string `skip` (case-insensitive, whitespace-trimmed), set:
- `test_command_mode: skip`
- `test_command_argv: []`
- `test_command_confirmation: none`
- `test_command_reentry_count: 0`

Skip the validation sequence below and proceed to the next phase. The merge agent will not invoke any test command.

Otherwise, run the full validation sequence:

1. **Hard control-character rejection (NO soft-stop).** The submitted command must match `^[^\x00-\x1F\x7F]+$`. If it contains any ASCII control character (\x00–\x1F or \x7F, including newlines, carriage returns, tabs as separators, etc.), reject the input outright. Increment `test_command_reentry_count` by 1, surface the issue, and re-prompt. This is a HARD block, not a soft-stop. Rationale: control characters in a test command have no legitimate use; their presence is either a paste accident or an attempt to exploit shell newline-as-command-separator semantics.

2. **Tokenize into argv (foreman side).** After the control-char check passes, tokenize the command using POSIX shlex-style splitting: whitespace separates tokens; single quotes preserve verbatim contents; double quotes preserve with backslash escapes; backslash escapes the next character outside quotes. Store the tokenized result in `build-state.md` Metadata under `test_command_argv:` as a JSON array. Keep `test_command:` as the verbatim original string (audit only — NEVER passed to a shell). Set `test_command_mode: run`.

3. **Runner-pattern check on argv[0] (soft-stop).** The first element of the tokenized argv must match the allowlist of known test runners: `pytest | npm | npx | pnpm | yarn | bun | jest | vitest | cargo | go | rspec | mocha | tox | make | just | task | deno`. If it does not, surface a soft-stop confirmation: "Test command runner `<argv[0]>` is not in the known-runner allowlist. Confirm intentional or revise."

4. **Metacharacter check per argv element (soft-stop).** No individual argv element may contain `[;&|<>` + backticks + `$(`. (Tokenization already removed whitespace and resolved quoting; what's left in each element should not contain shell metacharacters unless intentional.) If any element contains a flagged character, surface a soft-stop confirmation.

5. **Record final confirmation classification.** Based on which soft-stops fired and Danny's confirmations:
   - Neither soft-stop fired → `test_command_confirmation: none`
   - Only runner-pattern fired → `unknown-runner`
   - Only metachar fired → `metachar-in-args`
   - Both fired → `multiple`

`test_command_reentry_count` reflects total control-char rejections during input gathering (independent of soft-stop confirmations). The two fields together give the full audit picture: `_reentry_count` says how many bad inputs preceded the accepted one; `_confirmation` says the classification of the final accepted command.

6. **Pass argv to merge agent in structured form.** The merge agent's prompt template substitutes `test_command_argv: <JSON array>` and `test_command_mode: <run|skip>` (not `test_command: <string>`). When `test_command_mode == run`, the merge agent invokes tests by running `<argv[0]>` followed by each subsequent `<argv[i]>` individually shell-quoted — e.g., `pytest '-q' '--tb=short'`. When `test_command_mode == skip`, the merge agent does not invoke tests at all. No re-concatenation of the original string anywhere in the merge agent's invocation path.

## Run ID and chunk naming

Capture a single run timestamp at the start of Phase 1: `RUN_ID = <YYYYMMDD-HHMM>` (e.g., `20260512-2235`). Every chunk-id, branch, and worktree for this run is prefixed with `RUN_ID`:

- Chunk-id format: `<RUN_ID>-<chunk-slug>` (e.g., `20260512-2235-auth-refactor`)
- Branch format: `feature/<RUN_ID>-<chunk-slug>`
- Worktree path: `../worktrees/<RUN_ID>-<chunk-slug>`

This makes every run idempotent — a re-run of parallel-build on the same project at a later time gets a different `RUN_ID` and never collides with prior artifacts.

**Phase 2 preflight:** before any `git worktree add`, run `git branch --list "feature/<RUN_ID>-*"` and `ls ../worktrees/<RUN_ID>-*`. If either returns hits, fail loud and surface to Danny — do NOT silently reuse them.

## Phase 0 — Resume / Recover (conditional)

Runs ONLY if Danny invokes parallel-build with an explicit RUN_ID to resume, or selects a "resume previous run" option from the start prompt. Otherwise skip to Phase 1.

1. **Read** `build-state.md` for the supplied (or discovered) RUN_ID. If multiple runs exist in the repo and Danny didn't specify, list them and let him pick.
2. **Probe each chunk's actual state.** For each row in the chunk table:
   - Branch existence: `git branch --list "feature/<RUN_ID>-<chunk-slug>"`
   - Worktree existence: presence of `../worktrees/<RUN_ID>-<chunk-slug>/`
   - Canonical-path containment still satisfies the rule (see Phase 2 containment check)
   - Last commit on the branch (`git -C <worktree> rev-parse HEAD`)
3. **Reconcile stale `running` rows.** If `build-state.md` shows `running` but no live agent process exists and the branch HEAD matches the build-state's `commit-sha`, mark the chunk `unknown` (likely completed before crash). If branch HEAD differs from build-state, mark `unknown — branch HEAD diverged from recorded SHA`.
4. **Present recovery options** via `AskUserQuestion` with these three options:
   - **(A) Resume forward** — accept current state as ground truth. Chunks marked `complete` are merge-ready; `unknown` and `blocked` chunks need re-run or skip decision per chunk (further `AskUserQuestion` per chunk; allowed transitions per the lifecycle).
   - **(B) Abort cleanly** — run Phase 5 cleanup for all chunks per the chosen retention mode, archive partial build log, exit. No merge.
   - **(C) Inspect only** — print the reconciled state and exit without changes.

The skill assumes one parallel-build run at a time per repo; concurrent runs against the same repo are out of scope (the Phase 2 preflight catches the branch-name collision case).

## Phase 1 — Foreman decomposition (Claude main thread)

**Step 1a — Interface contract freeze (BEFORE decomposition).**

Read the plan end-to-end. Identify shared interfaces that multiple chunks will touch: types, API endpoints, database schema fields, file formats, migration order, public function signatures. Write these to `<repo>/contracts.md`:

```markdown
# Contracts — <project> — <RUN_ID>

## Shared types
<for each shared type: name, definition / signature, which chunks consume it>

## API endpoints
<for each endpoint: path, method, request schema, response schema, which chunks own / consume>

## Database schema changes
<for each table/column: change, migration version, which chunk owns the migration>

## Migration order
<numbered list of migrations that must run in sequence>

## File formats
<for each shared file format: schema/structure, which chunks read or write it>

## Generated paths

Path globs the merge agent treats as generated code (unconditional-escalate on conflicts):

- `__generated__/**`
- `dist/**`
- `build/**`
- `target/**`
- `*.gen.*`
- `*.generated.*`
- `node_modules/**`

(Defaults shown above. Danny edits this list in Phase 1 review.)
```

Show Danny `contracts.md` and get explicit approval before proceeding to Step 1b.

**Step 1b — Decompose into chunks.**

Identify natural seams: separate files, separate modules, separate API surfaces, independent migrations. Decompose into N chunks (target 2-6). For each chunk, write to `<repo>/build-manifest.md`:

```markdown
# Build Manifest — <project> — <RUN_ID>

## Chunk 1: <name>
**Chunk-id:** <RUN_ID>-<chunk-slug>
**Assigned:** claude | codex
**Worktree:** ../worktrees/<RUN_ID>-<chunk-slug>
**Branch:** feature/<RUN_ID>-<chunk-slug>
**Files (expected):** <list of paths the agent will create or modify>
**Depends on:** <chunk-ids that must merge first, or "none">
**Brief:** <1-paragraph task description>
**Acceptance:** <bullet list of what done looks like>
**Contracts:** <reference to which sections of contracts.md this chunk must conform to — quoted verbatim into the agent's prompt at Phase 3>
```

**Step 1c — Coupling check.** Before assigning agents: if any two chunks list overlapping files, you have not decomposed cleanly. Either re-split or sequence them. If two chunks both consume the same contracts.md section but neither owns it, declare an owner explicitly in the manifest.

**Step 1d — Assignment heuristic:**
- Codex: backend logic, data transformations, algorithm-heavy work, tasks with clear contracts
- Claude: tasks needing repo-wide context, frontend with the existing component library, work that requires reading lots of unrelated files
- Tie-break: balance the work roughly evenly

**Step 1e — Initialize build-state.md.** One row per chunk with `status: pending`. Initialize Metadata section with all known fields. Initialize Per-chunk metadata for each chunk with defaults (`contracts_revision_echoed: pending`, `scope_decision: none`, `serialization_warning_fired: no`).

**Step 1f — Initialize manifest-overrides.md.**

```markdown
# Manifest Overrides — <project> — <RUN_ID>

(Append-only. New entries go at the end. Each entry records a scope-adjudication option-A approval.)
```

**Step 1g — Capture BASE_REF.** Try `git symbolic-ref refs/remotes/origin/HEAD` to discover the upstream default branch (returns e.g. `refs/remotes/origin/main`); strip the prefix. If that fails (no `origin/HEAD` set), prompt Danny via `AskUserQuestion` with the list of local branches as options. Store `BASE_REF: <branch-name>` in `build-state.md` Metadata.

**Step 1h — Capture canonical repo root.** `repo_canonical_path = (Resolve-Path "<repo>").ProviderPath` (PowerShell) or `realpath "<repo>"` (bash). Store in `build-state.md` Metadata as `repo_canonical_path`. This is the reference point for Phase 2 containment checks.

**Step 1i — Approval.** Show Danny `contracts.md`, `build-manifest.md`, and `build-state.md`. Get explicit approval before Phase 2.

## Phase 2 — Worktree setup

For each chunk, from the repo root:

```bash
cd "<repo>"
git worktree add "../worktrees/<RUN_ID>-<chunk-slug>" -b "feature/<RUN_ID>-<chunk-slug>"
```

After each successful `git worktree add`:

1. Capture the canonical resolved path:
   - PowerShell: `(Resolve-Path "../worktrees/<RUN_ID>-<chunk-slug>").ProviderPath`
   - Bash: `realpath "../worktrees/<RUN_ID>-<chunk-slug>"`
2. Append the canonical path to the chunk's row in `build-state.md` under `canonical-worktree`.
3. **Containment check (hard block):** assert that `canonical_worktree` starts with `<canonical_repo_parent>\worktrees\`, where `canonical_repo_parent` is the directory containing `repo_canonical_path` (i.e., the parent of the repo root, since worktrees live at `../worktrees/`). If the assertion fails, mark the chunk `blocked: containment violation — canonical path <path> is outside expected scope`, do NOT spawn the agent, surface to Danny via `AskUserQuestion`.

If a worktree path collides with an existing one (Phase 2 preflight should have caught this, but defense-in-depth), halt and ask Danny.

## Phase 3 — Parallel execution

Launch all agents in a single message (multiple tool calls in one block) so they actually run concurrently. Each agent's prompt MUST include verbatim the relevant excerpt from `contracts.md` (cited in the manifest's `**Contracts:**` field) AND the current `contracts_revision` (SHA-256 of `contracts.md` content at prompt-write time). Each agent's report-back MUST include start and end ISO 8601 timestamps and an echo of the `contracts_revision`.

### Contracts revision token

Before writing each agent's prompt: compute `contracts_revision = sha256(<contracts.md content>)`. Embed it in the prompt template (see below). When the agent reports back, validate that the echoed token matches. The merge agent rechecks at merge time against the THEN-current contracts.md content; if `contracts.md` was edited mid-run during scope adjudication, agents that completed against the old revision will fail the merge-time check and be flagged for Danny.

### Claude chunks

Use the `Agent` tool with `subagent_type: "general-purpose"`. Prompt template:

```
You are coding chunk <chunk-id> of a parallel build. Your worktree is <absolute worktree path>. Work ONLY inside that worktree — do not touch files outside it.

contracts_revision: <hash>
(Echo this revision string verbatim in your final report. If you cannot conform to the contracts below for any reason, do NOT silently fork — report the conflict and halt.)

Plan: <chunk brief from manifest>

Acceptance criteria:
<bullets from manifest>

Contracts you must conform to:
<verbatim excerpt from contracts.md per the manifest's **Contracts:** reference>

When done:
1. Run any chunk-local tests if they exist.
2. Commit your work with message "feat(<chunk-id>): <short summary>".
3. Report back: files changed, commit SHA, start_timestamp (ISO 8601), end_timestamp (ISO 8601), contracts_revision (echoed verbatim from above), any decisions you made that diverged from the plan, any blockers.
```

### Codex chunks

**File-based prompt delivery is mandatory.** Do NOT use `$(cat <<'PROMPT' ... PROMPT)"` bash-substitution heredoc — that pattern fails silently in Claude Code's bash environment (Codex receives an empty prompt argument, falls into stdin-read mode, hangs). See the sibling `design-loop` SKILL.md for the documented failure mode.

The correct pattern:

1. Write the prompt to a file with the `Write` tool: `<absolute worktree path>/.codex-chunk-prompt.md`. Content uses the same shape as the Claude prompt above, including the `contracts_revision` line.
2. Invoke Codex via bash with stdin redirected from the prompt file:

```bash
cd "<absolute worktree path>" && \
codex exec \
  --sandbox workspace-write \
  --model "<configured model>" \
  --output-last-message ./.codex-report.md \
  < ./.codex-chunk-prompt.md \
  2>&1 | tee ./.codex-chunk.log
```

3. After `codex exec` exits, read `./.codex-report.md` for the agent's report.

If `codex exec` returns non-zero, capture stderr from `./.codex-chunk.log` and report to Danny — do not silently retry.

### Chunk failure — dependency-aware partial continuation

The legacy "report non-zero and stop the whole round" behavior wastes work. If a chunk fails:

1. Mark its `build-state.md` row `status: blocked` with the captured error in `blocker`.
2. Identify chunks that transitively depend on the blocked chunk (via the manifest's `**Depends on:**` graph). Mark those `status: blocked` with `blocker: depends on <failed-chunk-id>`.
3. All other chunks continue to completion.
4. Phase 4 merges the dependency-closed subset of successful chunks. If any chunk is blocked, the integration branch name carries a `-partial` suffix: `integration/<project>-<RUN_ID>-partial`.

### Post-completion scope check

After each chunk reports complete: run `git diff --name-only $(git merge-base $BASE_REF feature/<RUN_ID>-<chunk-slug>)...feature/<RUN_ID>-<chunk-slug>` and compare against the chunk's `Files (expected):` list from `build-manifest.md`. Any files in the diff but NOT in the expected list are "unexpected." If unexpected files exist:

1. Record them in `build-state.md` under the chunk's `unexpected-files:` column.
2. Surface to Danny via `AskUserQuestion` with exactly three options:
   - **(A) Accept the unexpected changes** — append a new entry to `manifest-overrides.md` (timestamped, chunk-id-keyed, original and updated expected files, reason). Set chunk `status: complete`. The build-manifest.md itself remains immutable.
   - **(B) Revert the unexpected files** — instruct the agent to re-run scoped only to the expected file list (the chunk goes back to `running`).
   - **(C) Abort the chunk** — mark it `blocked: scope violation`, treat as failed per the dependency-aware continuation rules.

The selected option (A/B/C) is recorded in `build-state.md` Per-chunk metadata as `scope_decision: <A|B|C>` (with the `manifest-overrides.md#override-N` reference for A only).

### Concurrency observability

After each chunk completes, the foreman updates `build-state.md` Metadata with derived parallelism fields:

- `overlap_minutes: <N>` — sum of pairwise (start, end) time-window overlaps across all completed chunks so far
- `parallelism_detected: yes | no` — `yes` if `overlap_minutes` > 1 minute for any completed pair; `no` if multiple chunks have completed with zero pairwise overlap; `unknown` if fewer than 2 chunks have completed

If `parallelism_detected` transitions to `no` (multiple chunks complete with no overlap), surface a SINGLE non-blocking warning to Danny in chat: "Agents ran sequentially so far (no time overlap between chunks <A> and <B>). Claude Code may have serialized the launches — captured in build log; no auto-retry." Per-chunk metadata records `serialization_warning_fired: yes` to prevent the warning from firing more than once per run.

## Phase 4 — Merge integration (dedicated Claude agent)

Once all running chunks have reported (success or blocked), spawn ONE Claude subagent dedicated to merging. Prompt template:

```
You are the merge integrator for a parallel build. Repo: <repo path>. RUN_ID: <RUN_ID>. BASE_REF: <branch-name>.

Chunks to merge (in dependency order, successful only):
<list: chunk-id, worktree path, branch, depends-on, commit-sha, contracts_revision_echoed>

Chunks blocked or skipped:
<list with blocker reason; do not merge these>

Current contracts.md SHA-256: <current-hash>

test_command_mode: <run | skip>
test_command_argv: <JSON array, e.g. ["pytest", "-q", "--tb=short"] or [] if mode is skip>

Your job:
0. Stale-contracts check: for each chunk above, compare its contracts_revision_echoed to current contracts.md SHA-256. If any mismatch, do NOT merge that chunk — flag it for Danny review as "stale contracts: chunk was against revision <X>, current is <Y>." Merge the dependency-closed subset of chunks whose contracts match.
1. Create integration branch: git checkout -b integration/<project>-<RUN_ID> (or integration/<project>-<RUN_ID>-partial if any chunks are blocked or stale).
2. For each successful chunk in dependency order:
   a. Merge: git merge --no-ff feature/<chunk-id>
   b. If merge succeeds clean: continue.
   c. If conflict: classify each conflict against the decision table below and act per the authorized action. Tag every resolved conflict with its class in the merge report.
3. After all clean merges:
   - If test_command_mode == run: invoke the test command as a structured argv invocation — run argv[0] followed by each subsequent argv[i] individually shell-quoted. Do NOT re-concatenate the original test_command string anywhere in the invocation. Capture full output.
   - If test_command_mode == skip: do not invoke any tests. Note in the report: "Tests skipped per Phase 1 input."
4. Report: integration branch name, files changed by chunk, conflict class counts (mechanical-formatting: N, mechanical-import-order: N, mechanical-trivial-merge: N, lockfile: N, generated-code: N, semantic: N — and within each, how many were auto-resolved vs escalated), test result, list of semantic-conflict escalation bundles (see format below).
```

**Conflict decision table** (authoritative — any auto-resolution outside this table is forbidden):

| Class | Definition | Authorized action |
|---|---|---|
| `mechanical-formatting` | Whitespace, line endings, trailing newlines only | Auto-resolve; prefer the side whose format check passes |
| `mechanical-import-order` | Import statement reorderings only (no added/removed imports) | Auto-resolve; apply the project's formatter if one exists |
| `mechanical-trivial-merge` | One side is a strict superset of the other (e.g., one side adds a new function, the other side doesn't touch the file) | Auto-resolve; keep the superset |
| `lockfile` | Conflicts in `package-lock.json` / `Cargo.lock` / `uv.lock` / `Pipfile.lock` / `yarn.lock` / `bun.lock` / `pnpm-lock.yaml` | Route per the lockfile policy chosen in Phase 1 inputs |
| `generated-code` | Files matching path globs in `contracts.md` ## Generated paths | Escalate unconditionally |
| `semantic` | Different implementations of same interface, contradictory logic, schema disagreement, contracts.md divergence | Escalate via the standardized bundle (below) |

**Lockfile policy** — chosen at Phase 1 inputs:

- `confirm-with-Danny` (default): escalate every lockfile conflict to Danny with both lockfile diffs; do NOT auto-merge.
- `auto-regenerate`: run the standard lock command for the detected ecosystem with safe-mode flags. After regeneration, verify the result is byte-identical to one side of the conflict; if it diverges from both, escalate to Danny with the regenerated lockfile + both source lockfiles.

**Safe-mode regeneration commands** (mandatory for `auto-regenerate` mode):

| Ecosystem | Lockfile | Safe-mode command |
|---|---|---|
| npm | `package-lock.json` | `npm install --package-lock-only --ignore-scripts` |
| pnpm | `pnpm-lock.yaml` | `pnpm install --lockfile-only --ignore-scripts` |
| yarn (berry) | `yarn.lock` | `yarn install --mode=update-lockfile` |
| bun | `bun.lock` | `bun install --frozen-lockfile` |
| cargo | `Cargo.lock` | `cargo update --workspace --offline` |
| uv | `uv.lock` | `uv lock` |
| pip-tools | `requirements*.txt` | `pip-compile --no-emit-index-url` |

If the detected ecosystem is not in the table (or detection fails), ESCALATE to Danny instead of running an unknown regeneration. The merge report MUST include for each auto-regenerated lockfile: exact command run, tool version (`node -v`, `cargo --version`, `python -V`, etc.), registry source if applicable (`npm config get registry` or equivalent), regeneration result (`matches side A | matches side B | diverges from both → escalated`).

**Standardized semantic-conflict escalation bundle.** For each semantic conflict, the merge agent reports:

- **(a) File and line range:** path + line numbers
- **(b) Minimal repro diff:** smallest unified diff that contains both conflicting versions
- **(c) Impacted tests:** test files whose code paths cover the conflicting region (best-effort grep against test paths matching `tests/`, `__tests__/`, `*.test.*`, `*_test.*`, `*Tests.*`)
- **(d) Resolution candidate A:** name + 1-sentence intent + the diff if A is chosen
- **(e) Resolution candidate B:** name + 1-sentence intent + the diff if B is chosen
- **(f) Blast radius:** which other files import / depend on the conflicting region (best-effort grep)
- **(g) Recommendation:** A | B | neither — with one-sentence reasoning

Danny picks A, B, or neither for each conflict via `AskUserQuestion`. The selection is recorded in the build log.

The merge agent has authority for the auto-actions in the decision table only. Everything else — including any conflict that doesn't fit the table — escalates.

## Phase 5 — Cleanup and handoff

After integration succeeds (or after Danny resolves escalations):

1. Show Danny the integration branch name, test results, and any escalation outcomes.
2. Ask: merge to main now, or open as PR for human review?
3. If approved to merge: `git checkout $BASE_REF && git merge --no-ff integration/<project>-<RUN_ID>` (or `-partial` variant).

**Worktree cleanup policy matrix:**

| Chunk final status | `keep-all` retention mode | `ask-per-chunk` retention mode (default) |
|---|---|---|
| `merged` | Remove worktree + delete feature branch | Remove worktree + delete feature branch |
| `blocked` (any reason) | Move worktree to `../worktrees/failed/<chunk-id>` via `git worktree move`; keep feature branch | Ask Danny per chunk: remove (same as `merged` row), keep in place, or move to `../worktrees/failed/<chunk-id>` |

After cleanup decisions are executed:

4. Archive run-level artifacts to the build log: `<repo>/build-log-<RUN_ID>.md` containing the final `build-manifest.md`, `manifest-overrides.md`, `contracts.md`, and `build-state.md` content (each in its own section), plus the merge agent's full report, plus Danny's escalation decisions.
5. Bare-path output the build log to Danny.

## Guardrails

- Foreman always shows `contracts.md` AND `build-manifest.md` to Danny before spawning agents. No silent decomposition or contract drafting.
- **`build-manifest.md` is immutable after Phase 1 approval.** Scope-adjudication option A appends to `manifest-overrides.md` instead; the merge agent reads `manifest + overrides` deterministically. No in-place manifest edits.
- **`contracts.md` revision check.** Each agent prompt embeds `contracts_revision: <sha256>` at prompt-write time; each agent must echo it back. The merge agent rechecks against the current contracts.md hash before merging — mismatches are flagged as stale and not merged.
- **Test command never reaches a shell as a string.** The verbatim `test_command` is audit-only. The merge agent receives `test_command_argv` (JSON array) plus `test_command_mode` and invokes argv[0] followed by each argv[i] individually shell-quoted when mode is `run`. Control characters in the input are HARD-rejected at the foreman's input gate (no soft-stop). When mode is `skip`, no test command runs at all.
- **Codex invocations MUST use file-based stdin redirection** (`codex exec ... < ./prompt-file.md`). Heredoc-via-bash-substitution (`$(cat <<'PROMPT' ... PROMPT)"`) is forbidden — it fails silently in Claude Code's bash environment. See `design-loop` SKILL.md for the documented failure mode.
- **Phase 2 containment check is a hard block.** Worktrees whose canonical paths escape `<canonical_repo_parent>\worktrees\` never run agents — the chunk is marked `blocked: containment violation`.
- Agents are forbidden from writing files outside their worktree. Within their worktree, files written must match the manifest's expected list; the post-completion scope check enforces this with Danny adjudication if violated.
- Merge agent has auto-action authority ONLY for the entries in the conflict decision table. Every other class — and any conflict that does not cleanly fit a class — escalates.
- Semantic conflicts always escalate via the standardized bundle. The merge agent does not invent resolutions.
- Lockfile conflicts follow the policy chosen at Phase 1 inputs. In `auto-regenerate` mode, ONLY the safe-mode commands in the table above are authorized — unknown ecosystems escalate. Generated code (per `contracts.md ## Generated paths`) always escalates.
- If two agents return conflicting interpretations of the same `contracts.md` section, the plan was ambiguous — fix `contracts.md`, restart the affected chunks. Old in-flight chunks will fail the revision-token check at merge time. Do not paper over it in code.
- If the test suite fails after integration, do not auto-debug across worktrees. Report the failure and ask Danny how to proceed.
- Codex runs with `--sandbox workspace-write`, NOT `danger-full-access`. Never elevate without explicit Danny approval per run.
- `build-state.md` updates are atomic full-file rewrites via the `Write` tool, never in-place edits. The schema (fixed table columns + Metadata section + Per-chunk metadata) is closed — no ad-hoc keys. The Per-chunk metadata defaults table is authoritative for absence semantics.
- Run-level idempotency: every run gets a `RUN_ID` prefix on chunks, branches, and worktrees. The Phase 2 preflight catches accidental reuse. Phase 0 — Resume/Recover is the path to resume an interrupted run; never silently reuse a prior run's artifacts.

## Dialogue Log

### Round 1
- **Codex headline:** Core shape is good but the spec assumes execution behaviors that are either known-broken (heredoc-substitution for Codex prompts) or under-specified (parallel launch semantics, merge authority boundaries, chunk failure handling); needs hardening on prompt transport, chunk contracts, and recovery/integration control flow.
- **Claude headline:** Accepted 8 items outright (heredoc bug, dependency-aware partial continuation, escalation bundle, build-state.md, cleanup matrix, post-run scope diff, conflict decision table, date-prefixed run IDs); countered 5 with narrower scopes.
- **Provenance:** ts=`2026-05-12T22:35:36.1199983-04:00`, pwd=`D:\Claude\_Claude-Workspace\.claude\skills\parallel-build`, canonical=`D:\Claude\_Claude-Workspace\.claude\skills\parallel-build`, prompt SHA-256=`291B69C8E02B00BDBC4C52EB9AE4681AFB8711AF8DA80C0F18CB354CE393D45A`
- **Verdict:** `MATERIAL_CHANGES_NEEDED` | **Confidence:** `high — main failures are concrete runtime/contract defects, not stylistic wording, and they directly affect whether the skill can execute reliably.`
- Full files: ./design/codex-feedback-v1.md, ./design/claude-response-v1.md
- Counts: Accepted 8, Rejected 0, Deferred 0, Countered 5

### Round 2
- **Codex headline:** Design substantially stronger after Round 1, but several "counter" responses still treat guardrails as audit-only when they need lightweight enforcement at execution boundaries; biggest examples are contract drift detection and canonical-path containment.
- **Claude headline:** Accepted 9 items (manifest-overrides.md, BASE_REF discovery, canonical-path containment, lockfile safe-mode, Phase 0 Resume/Recover, live parallelism warning, build-state schema, generated-paths source, contracts revision token); held one COUNTER on test-command argv. Shifted on 2 Round 1 counters where Codex pushed back well.
- **Provenance:** ts=`2026-05-12T22:40:45.7840224-04:00`, pwd=`D:\Claude\_Claude-Workspace\.claude\skills\parallel-build`, canonical=`D:\Claude\_Claude-Workspace\.claude\skills\parallel-build`, prompt SHA-256=`9C741597C134BD15B85A9D2BB2202F8DF2AC3E17AD64745B899DE784FA518398`
- **Verdict:** `MATERIAL_CHANGES_NEEDED` | **Confidence:** `high — the remaining gaps are architectural control-boundary issues, not wording, and they affect correctness and safety in real runs.`
- Full files: ./design/codex-feedback-v2.md, ./design/claude-response-v2.md
- Counts: Accepted 9, Rejected 0, Deferred 0, Countered 1

### Round 3
- **Codex headline:** Design close to shippable but one substantive security boundary remained weak — test-command validation can be bypassed with newline/control-character payloads; needs argv tokenization before production-safe.
- **Claude headline:** Accepted all three Round 3 items including the Security-1 argv tokenization (after three rounds of pushback with a concrete newline-bypass scenario, I was wrong to keep countering). Logged an open question for design-loop: extend the repeat-reject pause rule to cover persistent COUNTERs (not just REJECTs).
- **Provenance:** ts=`2026-05-12T22:46:43.3871152-04:00`, pwd=`D:\Claude\_Claude-Workspace\.claude\skills\parallel-build`, canonical=`D:\Claude\_Claude-Workspace\.claude\skills\parallel-build`, prompt SHA-256=`26E68D82FD8EE433FA468626EC9B8FD9396A429F466EAA52BA1F3C8A254D9D83`
- **Verdict:** `MATERIAL_CHANGES_NEEDED` | **Confidence:** `high — only a small number of issues remain, but the command-execution gap is a real security boundary defect rather than polish.`
- Full files: ./design/codex-feedback-v3.md, ./design/claude-response-v3.md
- Counts: Accepted 3, Rejected 0, Deferred 0, Countered 0
- **Cap decision:** Danny chose "Run another round" to sanity-check Round 3 changes before finalizing.

### Round 4
- **Codex headline:** Round 3 landed cleanly on all three required items; remaining issues are contract-clarity refinements (test_command_argv type fork between array and "skip" sentinel; test_command_confirmation muddied by control-chars-rejected event value; lifecycle shorthand visually implies unknown→merged).
- **Claude headline:** Accepted all three Round 4 polish items: split argv from mode flag (`test_command_mode: run|skip` + `test_command_argv: <array>`); separate `test_command_confirmation` final-state from `test_command_reentry_count` event-count; rewrite lifecycle shorthand as explicit per-arrow declaration.
- **Provenance:** ts=`2026-05-12T23:00:56.7239581-04:00`, pwd=`D:\Claude\_Claude-Workspace\.claude\skills\parallel-build`, canonical=`D:\Claude\_Claude-Workspace\.claude\skills\parallel-build`, prompt SHA-256=`8B216C522E09B402EF7C0932C69ABD617008E9C69662BB8578E22CE7556A08E7`
- **Verdict:** `MINOR_POLISH_ONLY` | **Confidence:** `high — all required Round 3 landings are present and remaining items are contract-clarity refinements, not architecture or security blockers.`
- Full files: ./design/codex-feedback-v4.md, ./design/claude-response-v4.md
- Counts: Accepted 3, Rejected 0, Deferred 0, Countered 0
