# Throughput and hardware

At intake, measure the actual execution host after creating `build-state.md`:
`pwsh -NoProfile -File scripts/measure-build-host.ps1 -RunFolder <folder> [-Kind <kind>]`.
Per-process memory caps for test runners must come from measured peaks, never a guess.
Use run-folder history automatically (last 20 finished jobs, optionally filtered by kind, with 25% headroom and a 0.5 GB floor); without measurements, slot sizing falls back to 2 GB. Override with -MemoryPerJobGB only from measured workload peaks.
Repeat for each execution host, on resume and before heavy dispatch. A failed probe is an environment
gap to resolve, never evidence of an idle machine. Reconcile dt-job state with the process sample;
sampling alone cannot identify every sleeping VM or remote job. Record those reservations too.

Use the computed cap as a starting allocation, not a blanket limit: CPU slots default to
`max(1, floor(logical_processors / 4))`, less running heavy jobs. RAM slots are
`floor((free_RAM - headroom) / peak_RAM_per_job)`; default headroom is the greater of 2 GiB or 10% of
total RAM. The new-job cap is the smaller nonnegative slot count. Zero means wait or offload, never
force one job past the RAM ceiling. Record a measured reason for any override. Include every shard's
RAM in the job estimate. Free RAM already excludes running work; do not subtract its RAM twice.

Dispatch ready independent milestones/chunks through concurrent dt-job jobs with isolated worktrees,
roots, databases and ports. Keep dependency acceptance gates and load-bearing priority; independent
work need not wait for an unrelated milestone. Reconcile completions before filling freed slots.
Serialize integration branch compare-and-swap updates because they mutate one shared ref; rebuild on
the accepted base as required by the branch contract.

Allocate logical processors and memory across jobs and their nested runners. Give each brief its
host snapshot, heavy-job cap, CPU/shard budget, memory estimate, exact test command and serial reasons.
Use the project's sharded runner or pytest-xdist `-n <budget>` for isolated suites. Use `pytest -n auto`
only within a CPU allocation or when one suite owns the available budget. Verify xdist is installed;
add it through the project's test dependencies when authorized. Do not silently drop `-n` if it is
missing. Balance shards by work, not by file or test count: prefer dynamic distribution (xdist
`--dist worksteal`, or a runner queue that hands the next test to a free worker) so one slow group
cannot pin a single shard. When shards must be static, split by recorded per-test durations
(e.g. `pytest --durations=0` output or a durations file) and spread any known-slow group across all
shards. Every gate run rewrites that durations file from its own results, so the next run balances on
current timings; never hand-paste a one-time snapshot. Put the parallel command in the roadmap's verification manifest before acceptance: the gate
runs the named command verbatim. Keep the full test selection and fix-round budget.
Overlap the fix round with report-only work: once the independent review confirms a failed verdict and
its defect list, and no step still runs against or reads the candidate (testing and evidence collection
are done), start the fix round in a separate worktree; report wording corrections run alongside. Never
fix while a run is still testing the candidate.
Before each full rerun after a fix round, run the tests that cover the changed files plus any
fingerprint, manifest or hash checks over them (minutes, not the full pass); fix what they catch, then
start the full pass. The full pass still decides; the quick pass only saves a wasted full run.

For a serial plan decision, retain the concrete cause (shared DB/file state, fixed ports, one live
external service/quota, order dependence, irreversible/production step or memory ceiling), evidence,
scope and isolation/offload workaround considered. Newly discovered contention requires a recorded
plan/roadmap decision revision before affected work proceeds, not an unexplained serial fallback.
Keep safe work parallel. FS-58 is unchanged: pass dt-job `-ExclusiveReason '<cause>'` only for the
specific job needing the machine pytest lock; leave `exclusive_reason` empty otherwise. Do not use
that lock as a scheduler or a substitute for isolating a suite.
