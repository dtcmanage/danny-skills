# Context discipline

## Context discipline

These rules are enforced by scripts both hosts must call; the adapter gives each host's exact commands.

- **Claude startup:** `references/managed-resume.md`.

- **Decide throughput.** Read `references/hardware-parallelism.md`. At intake, after state creation,
  run `<skill>/scripts/measure-build-host.ps1 -RunFolder <folder> [-Kind <kind>]`; it records logical
  processors, RAM, other heavy jobs and the computed cap in build state. Refresh before heavy dispatch
  and on resume. Run independent jobs concurrently within that cap and pass worker/shard budgets in
  briefs. Use safe parallel suites (`pytest -n auto` within a CPU allocation, bounded `-n`, or project
  sharding); serial requires the plan's named cause. Resolve missing decisions before dispatch.
  Per-process memory caps for test runners must come from measured peaks, never a guess.
  FS-58 `exclusive_reason` stays opt-in; never lock unrelated safe work.

- **Run work as jobs.** Workers, tests, builds, and browser checks run as `<skill>/scripts/dt-job.ps1` jobs, never in coordinator foreground. Read only capped `dt-job status|wait -Json` envelopes, checking `report_verdict`/`failure_category`; run state is `run_status`, never event type. Run `dt-job reconcile` at start, resume and `wait_timeout`; handle stalls per `managed-resume.md`, never merely repeat a wait.
- **Read deeper deliberately.** Open job evidence only through `<skill>/scripts/read-evidence.ps1` (`-Lines a-b` or `-Grep`), never by reading stream logs or output files directly.
- **Mark bootstrap once.** After the mandatory reads and before the first dispatch, run `dt-job mark-bootstrap`; the context limits are measured from that point.
- **Rotate on the limit.** On a `checkpoint` context line, reach a safe stopping point and rotate. On a `rotate` line or `ROTATE_REQUIRED`, rotate as the adapter says: rewrite `_build-state.md`, write a handoff note, `dt-job request-continuation`, release the lease, end. Running jobs continue; verification is never skipped or shortened to save context.

The advisory rules below remain in force until the scenario 8 validation passes for each mode.

- **Never pull bulk payloads into the orchestrator.** Read the current milestone by line range and each reference once, when needed; keep only `-Json` verdict fields, redirect anything over about 40 lines to a file under the run folder and read the tail, give the verifier a commit range and subagents paths with sha256 pins, never pasted content: wrappers refuse prompts over 400,000 characters.
- **Subagents write to files and checkpoint.** Every chunk prompt carries the standing rules `assemble-codex-prompt.ps1` appends (no nested agents, output to files, no idle waits, checkpoint after about 100 tool calls to `<run-folder>/milestones/<mid>/continuation-<n>.md`). A `CONTINUATION_STATE` path means a fresh builder on the same router pick continues as the same attempt with its own `MODEL_SELECTION` line. Never message a builder that has done substantive work; a correction is a fresh dispatch. Size chunks by coherence.
- **Restart at milestone boundaries.** After step 6.i, past about 150 tool calls since start or last compaction, rotate as above; the watcher relaunches the run, whoever started it.

