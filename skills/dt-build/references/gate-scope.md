# Verified gate scope

`<danny-skills>` is the resolved canonical repo root.

## Exact gate command at every milestone

At intake, including auto-generated roadmaps and resumes, require `## Milestone gate commands` in the
roadmap: one fenced JSON object keyed by milestone-id, each with one nonempty `gateCommand` and its
release ship configuration path. If no ship configuration exists, record that absence and use the
explicit final gate command agreed in the design. Missing or ambiguous entries block intake; repair
the roadmap before build setup. This requirement applies to every milestone, not just cutovers.

Before each milestone acceptance, read that milestone's recorded `gateCommand` and its source ship
configuration, including a scope-specific release file when selected by the design. Compare it with
the final gate's actual command. A mismatch blocks acceptance until the roadmap and source agree.
Do not reconstruct the command from remembered test names or run a subset in its place: `npm test`
must remain `npm test` when it also runs button/contract checks; direct `vitest` is not equivalent.

Run the exact recorded command through the existing `record-gate.py` producer below as a tracked
milestone gate job, using `--scope "release"` for the same coverage contract as the final gate and
`--output "<run-folder>/milestones/<mid>/milestone-gate.json"`. Pass the actual milestone candidate
worktree, its committed SHA and all gate implementation/suite-map dependencies under the producer's
normal clean-tree contract. This runner preserves the command verbatim, including conditionals and
exit handling; do not substitute a normalized command from another acceptance runner. Read its exit
status, saved output and record. Require `gate.result: PASS`, integer-zero exit, matching current SHA,
and the exact recorded command before the ordinary milestone acceptance check can pass. Save that
evidence in the milestone acceptance row. Additional targeted verification does not replace this gate.

If commands, ship configuration or candidate code change, rerun the milestone gate before accepting.
The exact final gate still runs on the final candidate; a final-only PASS cannot retroactively supply
missing milestone evidence. Auto-generation and resume never waive the per-milestone requirement.

## Executable final-integration path

dt-build produces and verifies its final-integration evidence. The app gate owns suite selection
and execution. On the clean, committed final candidate, launch this producer as the tracked final
integration job; read its exit status, saved log and record before declaring the gate passed:

```bash
python3 "<danny-skills>/skills/dt-build/scripts/record-gate.py" \
  --working-tree "<app-worktree>" --command "<exact gate command>" --scope "release" \
  --contract-path "<gate implementation path>" --contract-path "<suite map path>" \
  --output "<run-folder>/final-integration.json" \
  --record "<earlier-run-folder>/final-integration.json"
```

Omit `--record` if no earlier external record exists; repeat it for other external records. Both
scripts also discover `<app-worktree>/.dt-build/**/final-integration.json`. The producer resolves
scope before execution, saves it as `gate_scope` in the integration record and passes the same JSON
in `DT_BUILD_GATE_SCOPE_JSON` to the exact command, executed with dt-ship's convention:
`pwsh -NoProfile -NonInteractive -EncodedCommand` with UTF-16LE Base64 and closed stdin.
The configured snippet retains PowerShell variables, conditionals, exceptions and exit semantics;
no wrapper appends an exit or changes error handling. Roadmap gates also use this runner and can
explicitly invoke `bash`, `sh` or `python3` within the PowerShell snippet. An adopting
app gate reads this variable through its documented input contract and honors `full_test`. No flag
or command substitution is added. An app without this input contract runs its normal conservative
gate; the runner still produces reusable evidence now. Do not put the producer inside its own app's
`gateCommand`: recording the same canonical repository or active record/log output again is refused,
even through another app, scope or output name. The inherited target stack permits nested recorder
calls for isolated fixture repositories with distinct outputs, including this recorder's own tests.

For inspection or an app's existing documented input, the same read-only resolver is executable:

```bash
python3 "<danny-skills>/skills/dt-build/scripts/resolve-gate-scope.py" \
  --working-tree "<app-worktree>" --command "<exact gate command>" --scope "release" \
  --contract-path "<gate implementation path>" --contract-path "<suite map path>" \
  --record "<run-folder>/final-integration.json"
```

`--command` must preserve `.ship.json`'s exact `gateCommand` when declared; otherwise explicitly
supply the roadmap's exact named gate and record the absence of a configured ship gate. `--scope`
names the coverage contract, e.g. `release`; unit-only evidence cannot replace release checks.
Repeat `--contract-path` for all transitive gate implementation, suite-map and configuration
files/directories. `.ship.json` is always included. Paths are literal, repository-relative POSIX
paths: no absolute paths, backslashes, colon (including a literal colon in a filename), empty
components, `.` or `..` components. No arbitrary exceptions or pathspec magic. Ignored files must
not hold gate inputs; they are outside Git evidence.

## Produced evidence and validation

The producer preserves all existing integration fields other than its owned `gate` and `gate_scope`.
It captures HEAD, committed tree and porcelain status before execution and again after completion.
It snapshots each declared dependency's committed tree entries (names, modes and object hashes)
from the actual candidate before execution, never retrospectively infers what was tested. The
`gate` contains `sha`, `tree_hash`, exact `command`, `scope`, normalized `contract_paths`,
`contract_snapshot`, `before`/`after` (`sha`, `tree_hash`, `status`), `clean`, `result`, `exit_code`
and `log_path`. The combined stdout/stderr log is beside the record as `final-integration.gate.log`.

Outputs must be external to the candidate repository or ignored within it. In particular, require
`.dt-build/` to be ignored before storing records there: unignored evidence dirties the candidate
and the producer refuses it. The resolver conservatively requires full testing if its delta contains
unignored `.dt-build/` evidence; it never silently excludes these paths. Tracked outputs, symlink
output paths and Git metadata destinations are refused, including the companion log. No ignore
rule or tracked file is modified by the producer.

The producer atomically invalidates an old gate PASS before launch, then atomically replaces the
record after execution. Nonzero exit, a dirty checkout or moved HEAD/tree yields FAIL and nonzero
producer exit. A crash leaves unusable FAIL evidence. A top-level integration `result`, when present,
must separately be PASS for reuse: a successful gate never overwrites a blocked verifier decision.
Retain required checks, normal gate output, approvals and final gate on the final committed SHA.

The resolver verifies full immutable SHA, matching committed tree and before/after clean snapshots,
PASS/integer-zero exit, dependency snapshot, exact command/scope/path set, ancestry and unchanged
gate dependencies through the current working snapshot. Missing/legacy/malformed/incompatible
records require full tests. A failure at the same SHA/command/scope/paths overrides a conflicting
success. A later failed candidate can use an earlier valid ancestor only with the whole later diff.
Records are trusted local evidence, not signed proof of execution.

## Selection and empty deltas

Choose the valid ancestor with the fewest commits reachable from HEAD but not that SHA; ties use SHA
then record path. Return `candidate_sha`, `gate_scope_base` (`sha`, `record_path`, `reason`),
`changed_paths`, `full_test`, `already_gated` and rejected-record reasons. The delta includes committed,
staged, unstaged, deleted, renamed and untracked paths. The resolver changes no working files/index.

**Current-HEAD PASS with an empty delta is evidence to validate, never an implicit zero-suite final
gate.** It returns `already_gated: true`, reason `current-head-evidence-requires-validation`, and
conservatively `full_test: true`. Run the normal full final checks. An app would need an explicit,
verified-evidence reuse contract before it could replace execution with validation; this shared
capability does not grant that permission or weaken any required final checks.

No usable record returns a null base and `full_test: true`: require every suite, with all tracked and
untracked paths listed for diagnostics. Errors require full testing or a blocked gate, never an
empty-diff shortcut or default live-release base. Resolve immediately before execution with exclusive
ownership of the candidate worktree; concurrent edits are unsupported. Recompute after any change.

This supplies shared producer/consumer support for avoiding repeated tests since a recent gate.
The original Command Center selector still compares against the live release until its separate
app-owner adoption follow-up is implemented (AI-108/permanent619, dependent on permanent493).
Existing app selectors can therefore still over-test. That noncritical performance/adoption work
does not block releasing the working shared capability. dt-ship authorization and live hash/smoke
proof are unchanged.

## RAM scratch

When `.ship.json` declares `scratch` (`{"mode": "auto|ram|disk", "capGb": N}`), `record-gate.py` runs the exact gate under `_system-tools/ram-scratch exec`, which keeps the gate's exit code and records `gate.scratch` in `final-integration.json`. Absent key or `disk` means no wrapper. See dt-ship `references/ship-config.md`.
