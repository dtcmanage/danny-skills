# Live-bug fast lane

Read this when Danny marks a patch as a live bug, or when a patch fixes a broken core flow in production
(the `core-flow` critical class in `review-fix-loop.md` section 7), while a dt-build run is in progress.

Why: in Command Center v2.1 (run `20261122-v21`, 2026-11-22) a live-bug patch waited about 3.5 hours
behind milestone file ownership; the coordinator invented a rule to "wait for the M09 owner". File
ownership exists to stop two milestone chunks from editing the same lines at once. It never applies to
a live-bug patch.

## Rules

1. **Own worktree from current main.** The patch runs in its own worktree on a branch cut from the
   current `main` (or the live release branch, if production runs from one), never from a milestone or
   integration branch, and never queued behind a milestone. It carries no milestone work.
2. **File ownership never blocks it.** A milestone that owns the same files keeps working; the overlap is
   settled after the patch ships (rule 5). Never wait for a milestone owner, a milestone gate or a review
   round to start, gate or ship the patch.
3. **Gate scoped to its own diff.** Its gate is the suites its own diff touches: changed paths from the
   worktree's base (current `main`) to the patch commit, mapped to suites as in `review-fix-loop.md`
   section 5, plus a live smoke of the broken flow. Not the milestone's gate, not the full suite of the
   run.
4. **Ships first.** Merge, push and deploy follow the normal approval rules: if the run's authority already
   covers a live-bug deploy, the launching session does it; otherwise it is one `await-danny` decision
   ("Ship the live fix for <flow> now?"), raised at once and ahead of any milestone stop. Deploys to one
   host never overlap: take the host lock, so a milestone deploy waits for the patch, never the reverse.
5. **Milestones rebase afterwards.** Every milestone branch that touches the same files rebases onto the
   new `main` once the patch is merged, reruns its own targeted tests (and the contract tests if the patch
   touched the contract), and continues. Record the rebase in the decision log.
6. **Record it.** One decision-log line: what broke, the patch commit, the gate result, the deploy, and
   which milestones rebased.

## Queue honesty

For every queued item (a milestone, a fix bundle, the live-bug patch), the coordinator states in the
checkpoint `status_line` and the decision log what it is waiting on and when it can start, in plain
words: "M10 waits for M09's merge, about 40 minutes" or "the live fix is not waiting on anything; its
gate is running". A wait that names no concrete blocker and no start time is not allowed: start the item,
or name the blocker. "Waiting for the owner" is never a blocker for a live-bug patch.
