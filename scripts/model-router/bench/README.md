# M01 task bank and golden review

`generate-fixtures.py --output <temporary-folder>` reproduces seeded synthetic
fixtures without changing the bank. Retained canary source and harness support
are copied from the bank; tests independently pin original canary source hashes.

Python grader dependencies are pinned in `requirements-grading.txt`. The React
render harness owns `tasks/ui-frontend-card/harness/package.json` and its lockfile.
Provision these controlled dependencies outside candidate execution. The grader
never executes a candidate's install or download instructions. React renders in
JSDOM; Tailwind utilities are compiled and DOM selection/preservation are asserted.
This checks behavior and computed layout rules, not pixel appearance in Chromium.

Review commands require an explicit bench state folder:

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills-router-internal-bench"
python scripts/model-router/bench/review.py --state .dt-build/internal-bench-20261002/review-state --port 0
```

Open the printed `http://127.0.0.1:<port>` URL to save choices. The generated HTML
is also suitable for a read-only preview; its controls require the running server.
`--generate-only` writes a preview and pending state without opening a server.
State layout is `golden-approval.json` and `review/<date>-golden-review.html` under
the supplied folder. Do not use live state for validation or approve for Danny.

All tasks must be approved for overall approval. Needs-change survives restarts.
Any bank byte/path change resets choices, regenerates HTML, and rejects stale
forms. SHA256 includes relative names and bytes of the entire task bank, including
support code and dependency lockfile; installed dependencies and Python caches
are excluded. Framework metadata remains provisional. The server binds only
127.0.0.1, rejects reserved ports and foreign Host/Origin, and uses a session CSRF
token. It sends no alerts and changes no runner, trigger, roster, or live state.
