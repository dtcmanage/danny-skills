---
name: dt-pipeline
description: "Run the full plan -> review -> build pipeline as one command. Trigger on /dt-pipeline <objective-or-handoff-path>, 'run the full pipeline on X', or 'plan, review, and build X'. Do NOT use for single-file fixes (do those directly) or for fuzzy objectives that still need grilling to define the endgame (that is dt-plan first)."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(git:*) Bash(pwsh:*) Read Write Edit Agent AskUserQuestion ScheduleWakeup"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 0.1.2
  changelog: "0.1.0 initial release: one-command plan -> dt-review -> dt-build orchestration. Stage-aware intake (objective / plan-draft.md / handoff / existing design-final enters the pipeline at the right stage), subagent-run review and build phases, ~10-minute one-line status cadence while subagents run (default on), rolling _build-state.md crash-resume checkpoint written from templates/build-state-template.md at every phase boundary and milestone completion, prod-write single-threading restated as binding, and the end-of-run 'ready to merge to main?' prompt."
---

# Pipeline Orchestrator

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

`dt-pipeline` runs the whole delivery pipeline — author the plan, converge it through `dt-review`, execute
it through `dt-build` — as one command, with a rolling crash-resume checkpoint and a steady status pulse.
It replaces the hand-dictated orchestration ("you author the plan, send it to a subagent for dt-review,
then use a subagent to send it to dt-build") with a single invocation.

## When this fires

Trigger when at least one is true:
- `/dt-pipeline <objective-or-handoff-path>`.
- Danny says "run the full pipeline on X" or "plan, review, and build X".
- Danny hands over an objective, a `plan-draft.md`, a handoff prompt, or a finalized design and wants it
  carried through to a rehearsed build without stage-by-stage dictation.

Do NOT fire for:
- Single-file fixes, bug fixes, copy edits, quick hacks — do those directly.
- Fuzzy objectives whose endgame still needs grilling to define — that is `dt-plan` first; feed its
  `plan-draft.md` back into this pipeline afterward.
- A single stage in isolation (`dt-review` on an existing plan, `dt-build` from an existing
  roadmap/design) — invoke that skill directly.

## Checkpoint contract — `_build-state.md`

The pipeline maintains ONE rolling checkpoint file: `_build-state.md` in the project's planning folder
(the folder holding `plan-draft.md` / `design-final*.md` / `roadmap.md`, typically `<project>/design/`).
Its exact shape is defined by `templates/build-state-template.md` in this skill folder — the single
source of truth every writer (this skill and `dt-build`) renders from, so every checkpoint is
structurally identical. It records: phase, current milestone, completed list, in-flight work, last
commit SHA, uncommitted artifacts, and the next step.

Rules:
- Rewrite the WHOLE file from the template at every phase boundary and at every milestone completion —
  atomic full-file rewrite, never an append or partial edit.
- Do not confuse it with `dt-build`'s run-folder `build-state.md`: that file is dt-build's internal run
  scaffold; `_build-state.md` is the pipeline-level checkpoint Danny and a resuming session read.
- Mark `status: COMPLETE` only after step 7's completion report.

## Procedure

0. **Intake and stage detection.** The argument is one of: a plain objective, a `plan-draft.md` path, a
   handoff-prompt path, or a project/planning folder. Resolve the project's planning folder, then detect
   the furthest completed stage and enter the pipeline there — never redo a finished stage:
   - `_build-state.md` exists and is not `status: COMPLETE` → **resume**: read it, announce phase /
     current milestone / next step in one line, and continue from exactly there instead of starting over.
   - A finalized design exists (`design-final-*.md`, or legacy `design-final.md`) → skip to step 3
     (roadmap/build).
   - A `plan-draft.md` exists (or the handoff contains one) → skip to step 2 (review).
   - Otherwise the objective enters at step 1 (plan).
   Confirm workstation/repo routing per the global rules; if the work clearly belongs to a different
   workstation than the session's, stop and confirm before proceeding. Ensure the git surface per
   `/start-work` (worktree for agent-executed build work).

1. **Plan.** Author `plan-draft.md` directly as the architect. Per the global rule: when the objective is
   already clear, do NOT run dt-plan's intake questions — pre-fill name, scope, and save path from
   context and proceed. Write the plan in the shape dt-review expects (including an
   `## Implementation Sequence` and `## Validation Gates` surface so the downstream roadmap producer has
   something to lift). Rewrite `_build-state.md` (`phase: plan` complete, next: review).

2. **Review.** Spawn a subagent to run `dt-review` on the plan to convergence. The subagent runs the full
   adversarial loop and returns the finalized design doc — `design-final-<slug>.md` (slug describing what
   is being built) in the planning folder. The spawn prompt MUST state dt-review's subagent contract
   explicitly: on any `USER_DECISION` cap gate or A/B/C adjudication, the agent immediately sends the
   full decision package (options, unresolved findings, state, recommendation) via SendMessage to this
   session and stays responsive for the relayed decision — never idles waiting for Danny directly.
   Relay each round's verdict in the status pulse; surface A/B/C adjudication questions to Danny
   immediately (that is a genuine fork, not a pause-for-approval).
   Rewrite `_build-state.md` (`phase: review` complete, design path recorded, next: build).

3. **Build.** Spawn a subagent to run `dt-build` from the design (or `roadmap.md` when one exists —
   dt-build auto-generates the roadmap from a design otherwise; for heavy builds prefer a deliberate
   `dt-roadmap` pass first, per dt-build's own guidance). dt-build rewrites `_build-state.md` after every
   milestone's acceptance gate passes (its step 6.h), so the checkpoint stays current without this
   orchestrator polling. Rewrite it yourself at the phase boundary (`phase: build` entered / complete).

4. **Status cadence (default on).** While any subagent runs, post a one-line progress update to Danny
   roughly every 10 minutes — phase, current milestone/round, and whether anything is blocked
   (e.g. `build: M03/M07 accepted, M04 in verify/fix attempt 1, no blockers`). Use `ScheduleWakeup`
   where available rather than blocking. Danny can turn the pulse off ("quiet mode") or retune the
   interval; default is on at ~10 minutes.

5. **Crash resume.** On ANY invocation, step 0's `_build-state.md` check is the resume path: a checkpoint
   not marked COMPLETE means a prior run died mid-pipeline. Trust the checkpoint over archaeology —
   verify its `last_commit_sha` and `uncommitted_artifacts` against the live tree (`git log`,
   `git status`), reconcile any drift, then execute its `## Next step`. Never restart a pipeline from
   scratch while an unfinished checkpoint exists without Danny explicitly saying to start over.

6. **Prod-write single-threading (binding restatement of the standing global rule).** When any pipeline
   step writes to a live system — a prod database, a deployed service, a live branch, an external API
   with side effects — single-thread it: send the full instruction for that one step, wait for the write
   to confirm, verify the result against the live system, and only then queue the next instruction to the
   subagent. Never batch a second instruction behind an unconfirmed prod write; async messages cross and
   a stale instruction can land after a correction.

7. **Completion.** When dt-build's acceptance ledger lands: rewrite `_build-state.md` with
   `status: COMPLETE`, then report — what shipped, the ledger verdict per milestone, the build branch,
   and bare absolute paths to the retained artifacts (plan, design, roadmap, ledger). Then proactively
   ask **"ready to merge to main?"** per the git rules and wait for the go-ahead before
   `/git-merge-feature` — or hand off to shipping directly if Danny says "ship it" / "push live"
   (rebase onto main, `--ff-only` merge, push, gates passing first).

## Guardrails

- One pipeline per project at a time: an unfinished `_build-state.md` blocks a fresh start (step 5).
- The orchestrator never redoes a converged stage; stage detection (step 0) is the entry contract.
- Subagents own their stage end-to-end; this skill does not reach into dt-review/dt-build internals —
  it feeds inputs, relays status, and reads outputs.
- Checkpoints only at genuine forks (A/B/C adjudication, a real blocker, an irreversible or
  outward-facing boundary) — the pipeline is an already-authorized multi-step process and runs start to
  completion in one pass.
- Report artifact locations as bare absolute paths per `../../references/conventions.md`.

## References

- Checkpoint template (canonical `_build-state.md` shape): `templates/build-state-template.md`
- Review stage contract: `skills/dt-review/SKILL.md`
- Build stage contract: `skills/dt-build/SKILL.md` (its step 6.h writes the same checkpoint)
- Roadmap producer (heavy-build option): `skills/dt-roadmap/SKILL.md`
