# CT202 checkout freshness

`<danny-skills>` is the resolved danny-skills repo root; `<workspace>` is the
canonical CT202 workspace repo root, `/home/danny/Claude`. Quote script paths
when substituting these roots.

`<danny-skills>/scripts/refresh-checkout.py` is install tooling, with no skill
runtime consumers. The workspace repo's
`<workspace>/_system-tools/workspace-sync/pull-skill-checkout.sh` adapter runs it
from the existing `<workspace>/_system-tools/workspace-sync/pull-workspace.sh`
SessionStart path. Install the pack
release first, then integrate the adapter through workspace sync. No settings
change, timer or skill-link repair is required. Removing the adapter call disables
the refresh; an absent helper is a no-op during staged integration.

The command-line entry point only runs on Linux from the canonical CT202
danny-skills checkout. It accepts no environment or CLI overrides for its repo or
approved HTTPS remote. Fixture tests import the function with disposable paths
and local remotes. Production uses existing GitHub Git credentials; terminal,
askpass and credential-manager interaction is disabled. It never contacts
SNOWWHITE. Fetch and push URLs must both resolve to exactly one approved URL.

Refresh requires clean `main`, no untracked files and no active Git operation or
known Git lock. It fetches only `main`, rechecks safety and HEAD, proves ancestry,
then merges the pinned fetched commit with `--ff-only` and autostash disabled.
Equal trees do nothing; local-ahead, divergent, detached, dirty and operation-in-
progress trees are preserved. Fetch failure cannot start integration or recovery.
No stash, rebase, reset, commit, push or operation abort is performed. Local hooks
and fsmonitor are disabled for this unattended transaction.

A nonblocking, crash-releasing lock serializes refresh calls. Ordinary manual Git
commands do not honor this lock: avoid mutating the canonical checkout while a
refresh is running, as with the workspace sync concurrency contract. Checks are
repeated after fetch; Git's own merge/index locking also rejects conflicting
edits. This is not a general lock against arbitrary concurrent file writers.

The whole helper has a 30-second startup allowance, including process-tree
cleanup on timeout or termination. This leaves the existing workspace fetch its
120 seconds within the 180-second SessionStart timeout. This allowance bounds
startup latency rather than promising a network completion time. A slow or
failed fetch skips until the next session. Results go to stderr; no new persistent
log or alert machinery is introduced. The adapter runs before workspace locking,
so workspace contention/failure cannot suppress skill freshness.

Local verification:
`python3 -m pytest -n 2 "<danny-skills>/scripts/tests/test_refresh_checkout.py" -q`.
The ship gate includes this Linux-only selection with two scheduler slots. Tests
use isolated disposable repos, local bare remotes and a controlled stalled-fetch
fixture; no live network or credentials are needed.
