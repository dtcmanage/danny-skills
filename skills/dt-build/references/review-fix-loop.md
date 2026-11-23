# Review and fix loop

Read this before acting on any verifier or review finding: the per-milestone verifier (SKILL.md step 6d),
a BLOCKED acceptance gate (6e), and the final integrated review (6.5). It replaces one-fix-per-finding
chains and full-suite reruns after every fix. Findings at release time (the final combined review, the
final milestone's acceptance, and dt-ship) follow section 7 instead of the `important`/`minor` rule.

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

- When a review round returns no open `important` finding (at release time: no open critical finding,
  section 7), run the full gate once on the final candidate
  SHA, before deploy, switch-over or merge. "Full" means every suite the change touches, chosen by
  changed paths (front end, back end, shared contract) per `00_Resources/build-process.md`, plus the
  builds, E2E groups and design-required live checks those paths need. That run writes
  `final-integration.json`.
- **Changed relative to what.** Changed paths are `git diff --name-only <base>..<candidate>`, where
  `<base>` is the most recent commit whose gate record is still valid:
  - A gate record is a `final-integration.json` (this run's `<run-folder>/final-integration.json`, or one
    left by an earlier dt-build run of the same repo in its run folder under `.dt-build/`) whose
    gate `result` is PASS and which names the gated SHA and the exact gate command.
  - It is still valid when (a) it passed, (b) its gate command equals the current `.ship.json`
    `gateCommand` (or the roadmap's named gate when there is none) and the gate configuration has not
    changed since that SHA: `git diff --quiet <record-sha>..<candidate> -- .ship.json <suite map>`, where
    the suite map is the file or folder the gate reads to map paths to suites, and (c) its SHA is an
    ancestor of the candidate (`git merge-base --is-ancestor <record-sha> <candidate>`).
  - Of the valid records, take the nearest ancestor of the candidate. Only when none is valid, fall back
    to the live release SHA (the commit production runs); never the live release when a newer valid
    record exists. (Command Center v2.1, 2026-11-22: comparing a 3-line fix to a live release far behind
    `main` selected every suite.)
  - Record the base in `final-integration.json` as `gate_scope_base: {sha, record_path, reason}` with the
    changed path list, so the next scoped gate and dt-ship can check it.
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

## 7. Release-time severity triage

Policy: `00_Resources/build-process.md`, "Minor findings at release time ship as known issues, not
blockers" (Danny, 2026-11-22). Why: in Command Center v2.1 (run `20261122-v21`) a minor finding at the
final milestone M07 (F1) re-opened a gated release candidate (operator notes n-021/n-022).

- **Where it applies:** the final combined review (step 6.5), the acceptance of the final milestone (the
  roadmap's release or `final`-category milestone that produces the ship candidate, including its step 6d
  verifier and 6e gate findings), any check that runs after the full gate on that candidate, and dt-ship.
- **Only critical findings block.** Critical is exactly one of: `core-flow` (a broken core user flow),
  `data-loss` (data loss or corruption), `security` (a security hole), `deploy-rollback` (a broken deploy
  or rollback). A review severity of `important` does not block on its own here.
- **Everything else is a known issue:** docs wording, cosmetic UI, a small edge-case bug, test or doc
  hygiene. Ship the already-gated candidate unchanged; no fix round, no new commit, no full-gate rerun.
- **Run the triage deterministically:** write the round's findings to `<run-folder>/release-findings-<stage>.json`
  (`id`, `milestone`, `type`, `what`, `where`, then `critical` + `critical_scenario` for a critical one or
  `why_not_blocking` for the rest) and run
  `pwsh -NoProfile -File "<danny-skills>/scripts/release-triage.ps1" -FindingsPath <that file> -Stage final-review|final-milestone -RunFolder <run-folder> -Json`.
  Exit 0 = ship; the known issues are now under `## Known issues` in `<run-folder>/deferred-findings.md`.
  Exit 2 = a critical finding: fix only the critical findings in one bundled fix (sections 2-4), then run
  the full gate once on the new SHA (section 5); the known issues stay logged and unfixed. Exit 1 = a
  finding is missing a field; fill it and rerun.
- **Release summary:** the acceptance ledger counts the `## Known issues` entries in its summary and lists them; the final report and
  `final-integration.json` notes name them; dt-ship carries them via `-KnownIssuesPath`.
- Record each critical/known-issue call in the decision log. A wrong `critical` claim (for example a
  docs typo labelled `security`) is a label correction under section 1, not a reason to block.
