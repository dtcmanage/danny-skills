# Cutover and migration rehearsal gate

- Apply `00_Resources/build-process.md`, "Rehearse a cutover or migration runbook end to end before
  the live attempt." For any cutover or migration, require the distinct rehearsal milestone specified
  by `dt-roadmap` and an explicit dependency from every live-switch milestone. If missing, stop before
  build setup and repair the design/roadmap; do not bypass it through design-only auto-generation.
- Before any live cutover attempt, read the rehearsal's acceptance evidence and confirm PASS: every
  exact final runbook command ran in order on a disposable copy of real data with the same interpreter
  flags, user and paths, including cleanup and verifiers; expected numbers were re-derived from current
  code; check scripts were proven against the live old system; and the owner's dependency answer and
  rollback decision were recorded. Unit tests and piecewise rehearsals are insufficient.
- Bind the pass to the runbook revision, code SHA, data-copy identity and gate expectations. Missing,
  failed or stale evidence blocks the live attempt. If commands, code or gate expectations change,
  rerun the entire rehearsal before attempting the switch, including after a failed live attempt.
- Treat broken check scripts as tooling failures: fix and rerun the check, never roll back the product
  over a broken harness. Follow the recorded dependency decision; when nothing needs the old system,
  keep it stopped and fix forward rather than resume it and invalidate the export.
- Run steps exceeding worker time limits detached with logs and orchestrator monitoring. Read each
  gate result before the next action; never chain a push or deploy onto a test command.
- Preserve this gate in live-switch worker briefs and checkpoints. A later ship gate or final
  integration rehearsal does not authorize an earlier live cutover.

