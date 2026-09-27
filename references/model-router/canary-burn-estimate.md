# Canary burn estimate

Current isolated dry-run scope, 2026-09-27: 6 picked models, of which 5 have applicable graded tasks; 16 model-task pairs at 3 runs each = 48 graded calls. `claude-haiku-4-5-20251001` has 1 task, `claude-opus-5-5` has 2, `claude-sonnet-5` has 5, `gpt-6-luna` has 1, and `gpt-6-sol` has 7. The image-only `gpt-image-2` pick has no applicable task and consumes zero tokens.

Per-call estimates include CLI fixed overhead: 23,000 input tokens for `codex exec`, 57,000 cache-creation input tokens for `claude -p`, and 600 output tokens for either lane. The input figures come from read-only first-turn measurements on real sessions on 2026-09-27: Codex about 23,000 and Claude 25,000-57,000. Claude input is priced at the cache-write rate. Total estimated burn is **1,920,000 input tokens, 28,800 output tokens, and $5.33205 API equivalent**. The dated Haiku snapshot uses the `claude-haiku-4-5` price key by longest-prefix match.

These constants are estimates, so actual quota use can differ.

Coding graders run the model's answer as Python on this PC under Danny's account with a 30 s timeout and network calls blocked; they are not a sandbox.
