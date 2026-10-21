# Resilience and Security

Intake resilience controls in Phase 7A:
- Branch drift detection via `<skill>/scripts/check-drift.ps1`.
- Worktree containment hard-block via `<skill>/scripts/check-worktree-containment.ps1`.
- Resume compatibility gate rejects legacy pre-refactor run folders.
- Contract validation fails closed on schema and dependency violations.

Execution resilience controls in Phase 7B:
- Outside watchers (a parent session, a cron check, a script) read the run's state from `dt-job status -RunFolder <run> -Json`:
  `run_status` and, when it is `awaiting_danny`, `awaiting` (operation, seq, since_utc). Never infer the state from the
  last event's type: a `continuation_requested` event can follow a stop while the run still awaits Danny (FS-94, a
  43-minute missed stop). Wait on a job with `dt-job wait -JobId <id> -TimeoutSec <n>`, never a sleep loop.
- Codex prompt assembly and verify gates run through deterministic scripts.
- Codex execution runs only through `<skill>/scripts/invoke-codex-chunk.ps1`, with cache-verified model resolution,
  explicit effort, a mandatory one-line selection reason, stdin prompt delivery, redacted logs, and retained
  provenance containing the canonical user-visible disclosure line.
- Verify/fix automation is capped at two implementation failures per milestone. Environment, tooling, and
  approved contract-revision failures are recorded but do not consume implementation attempts.
- Integration-branch updates run through compare-and-swap (`<skill>/scripts/branch-cas-update.ps1`) after rehearsal.
- Single dispatch: when a step must launch exactly one child (a one-shot review), pass `-SingleDispatch` to
  `invoke-codex-chunk.ps1` or `invoke-claude-chunk.ps1`. Every branch that would relaunch the child (the Codex
  capacity backoff, offline recovery, the unexplained-failure retry) then fails closed with
  `failure_category: single-dispatch-refused`; provenance records `single_dispatch` and
  `single_dispatch_refused_branch` (and the dispatch count). Without the switch, behavior is unchanged.
- Retry continuity: when `invoke-codex-chunk.ps1` re-dispatches after a retryable failure (capacity, offline,
  unexplained), the new attempt's prompt starts with a `CONTINUATION:` preamble naming the attempt number, the prior
  attempt's duration and failure, and the stream log, telling the worker that the job's own worktrees and commits are
  its prior work. The original prompt follows unchanged and keeps its provenance hashes; each dispatch attempt
  records `continuation_preamble`.
- Stopped-short detection: a Codex dispatch that exits 0 but whose final message's last paragraph asks for
  confirmation (`please confirm`, `confirm takeover`, `should I proceed`, ...; a closing follow-up offer such as "Do you want me to also..." is not a stop) fails with
  `failure_category: needs_input` (`CODEX_NEEDS_INPUT`), the question in `failure_detail`, and a non-zero exit. It
  is never retried.
- Process custody: both wrappers join a fresh Windows job object before starting the worker CLI
  (`<skill>/scripts/worker-process-tree.ps1`), so every descendant is tracked even after its parent exits. Once the CLI
  exits or times out, output drains for at most 30 seconds; a descendant still holding the pipes is stopped,
  then every remaining descendant is stopped, so no worker child outlives its dispatch. Provenance records
  `process_custody` (`job_object`, `job_object_unavailable`, `unsupported_platform`) and `orphans_stopped`
  (pid, name, working set). Outside Windows the drain is still bounded.

Shared posture:
- Use repo-level `references/security-posture.md` as the policy anchor.
- Route run-log writes through repo-level redaction module.
