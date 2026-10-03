# Internal benchmark task bank and golden review

`generate-fixtures.py --output <temporary-folder>` reproduces seeded synthetic
fixtures without changing the bank. Retained canary source and harness support
are copied from the bank; tests independently pin original canary source hashes.

Python grader dependencies are pinned in `requirements-grading.txt`. The React
render harness owns `tasks/ui-frontend-card/harness/package.json` and its lockfile.
Provision these controlled dependencies outside candidate execution. The grader
never executes a candidate's install or download instructions. React renders in
JSDOM; Tailwind utilities are compiled and DOM selection/preservation are asserted.
This checks behavior and computed layout rules, not pixel appearance in Chromium.

Windows alone owns benchmark/research execution, approvals and reporting; Mac is an observer.

Research, eligible new-model detection and observed performance drift automatically request comparisons. Benchmark execution generates the golden-review page and pending state. The weekly report surfaces pending approval. To review the actual Windows bank, use the permanent router bench state:

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
python scripts/model-router/bench/review.py --state "../model-router/state/bench" --port 0
```

Open the printed `http://127.0.0.1:<port>` URL to save choices. The generated HTML
is also suitable for a read-only preview; its controls require the running server.
`--generate-only` writes a preview and pending state without opening a server.
State layout is `golden-approval.json` and `review/<date>-golden-review.html` under
the supplied folder. For synthetic validation, supply a temporary state folder instead. Only Danny approves the answers and rubrics.

All tasks must be approved for overall approval. Needs-change survives restarts.
Any bank byte/path change resets choices, regenerates HTML, and rejects stale
forms. SHA256 includes relative names and bytes of the entire task bank, including
support code and dependency lockfile; installed dependencies and Python caches
are excluded. Framework metadata remains provisional. The server binds only
127.0.0.1, rejects reserved ports and foreign Host/Origin, and uses a session CSRF
token. It sends no alerts and changes no runner, trigger, roster, or live state.

## Release test counts

The combined Windows gate retains 14 suites and replaces the retired canary suite
with six exact benchmark successors, for 20 declared suites. Read the generated evidence for the actual pass/fail result; declared suites alone do not establish acceptance.

Each PowerShell benchmark suite increments its counter only after an existing
`Assert` succeeds, including checks inside loops and injected callbacks. The runner
captures both fresh refusal children, requires exactly one positive numeric summary
with zero failures from each, and adds those measured counts to its own checks.
Child output is prefixed so only the parent's final `SUMMARY` is authoritative.
A nonzero child exit, missing/empty summary, duplicate summary or invalid count
fails the parent. No count is inferred from scenario labels or assertion source lines.