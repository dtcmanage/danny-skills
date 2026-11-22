# Review and fix loop

Read this before acting on any verifier or review finding: the per-milestone verifier (SKILL.md step 6d),
a BLOCKED acceptance gate (6e), and the final integrated review (6.5). It replaces one-fix-per-finding
chains and full-suite reruns after every fix.

Why: the Command Center v2 final review (run `20261121-command-center-v2`, 2026-11-21/22) ran four
review rounds that spawned eight separate fix chunks (a docs fix had its own chunk) and thirteen full
gate runs over about seven hours, each fix verifier reading 15-80 KB diffs. One deploy bug (sessions
launched in the wrong folder on CT202) surfaced only in round 3, because no milestone had ever launched
a session on the real host.

## 1. Label every finding

Every verification and review prompt requires each finding to carry:

- **Type**, exactly one of:
  - `app-bug` — the product does the wrong thing (code, config, deploy script behavior).
  - `test-env` — the tests or gate are wrong: a wrong assertion, a skipped test that should run, fixtures,
    test isolation, gate script wiring.
  - `docs` — runbooks, checklists, README, comments, decision-log or deferral records.
  - `design-gap` — the design requires something that was neither built nor recorded as deferred, or the
    design itself is silent or wrong on the point.
- **Severity**: `important` (blocks PASS) or `minor`.
- **Where, scenario, fix, check** — the check is the targeted test or probe that proves the fix.

The orchestrator corrects a wrong label and records the correction in the decision log. A `design-gap`
whose fix changes the contract follows the `contract_revision` class (SKILL.md step 2.7) and stays out of
the bundle. Every other finding is decided in the same round: fixed in this round's bundle, recorded as a
named limitation, or written to `deferred-findings.md` with a one-line reason, per the "Default
implementation loop limit" in `acceptance-contract.md` and the SKILL.md step 6j criterion.

## 2. One bundled fix per round

- After a review round, write one fix brief holding every finding to fix, grouped by type, and dispatch
  one fix chunk in one worktree. Never split findings into per-finding, per-type or separate docs chunks.
- The bundle takes the strictest category any of its findings needs (protected when one touches a
  load-bearing, security-sensitive or live-write boundary).
- Split only when the bundle would exceed the prompt cap or two fixes need conflicting edits to the same
  lines; record the reason. Splits run in sequence on one branch, not as separate rounds.
- A round is: review, one bundled fix, one fix verification, targeted tests. The next review round then
  reads the updated candidate.

## 3. Test what the fix touched, not everything

- The fix brief names the test selection the worker runs, and the standing rule "full named test
  selection" means this set:
  - each finding's check test (new or corrected),
  - the existing test files for every module the fix diff touches,
  - any fingerprint, manifest or hash check over the changed files.
- The orchestrator reruns the same set on the fix commit and records command, exit code and evidence path.
- Do not run the full suite, full build matrix or full E2E groups after a fix round.

## 4. The fix verifier reads only the fix diff

- The verify brief carries the findings being fixed (with labels), the fix diff
  (`git diff <pre-fix-sha>..<fix-sha>`), and the targeted test results. It does not carry the combined
  build diff, the design or earlier review reports; the verifier may open surrounding code by path for
  context.
- It answers three questions: does each change resolve its finding; does the diff contain anything
  beyond the findings (an out-of-scope finding); does the touched code regress.
- A rejected fix gets one corrective bundled fix within the milestone's attempt cap
  (`acceptance-contract.md`, "Default implementation loop limit"), verified the same way.

## 5. Full suite once, at the end

- When a review round returns no open `important` finding, run the full gate once on the final candidate
  SHA, before deploy, switch-over or merge. "Full" means every suite the change touches, chosen by
  changed paths (front end, back end, shared contract) per `00_Resources/build-process.md`, plus the
  builds, E2E groups and design-required live checks those paths need. That run writes
  `final-integration.json`.
- If it fails, label the failures, make one bundled fix, rerun the failed tests plus its targeted tests and
  fix verification, then run the full gate once more. A failing full gate is the only reason to repeat it.

## 6. Real-host smoke inside the milestone

- A milestone whose code depends on the real target host (terminal multiplexer such as tmux, OS paths
  and file layout, service manager such as systemd, shell, deploy target config) runs a short end-to-end
  smoke on that host inside the milestone's acceptance (step 6e): do the one user action the milestone
  delivers (for example launch a session, send a reply), read back the result, clean up. Keep it to
  minutes and isolated (test socket, port and folder).
- If the roadmap's checks for that milestone lack it, quote the added smoke in the milestone's
  decision-log entry (step 6a) and run it. Unit tests and local fakes do not substitute. Classify a host
  failure per SKILL.md step 2.7.
