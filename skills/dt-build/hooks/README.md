# dt-build coordinator hooks

Claude Code hooks that enforce the dt-build context limit at the tool call. They ship as files only and are installed at adoption, never before.

- `coordinator-pretooluse.ps1` denies, in a dt-build coordinator session only: a Read of a file over 400 lines without `offset`/`limit`, image Reads (png, jpg, jpeg, gif, bmp, webp), and CronCreate. Past the hard context limit it also denies Read, Grep, Glob, WebFetch, WebSearch, Agent, Task, NotebookEdit, and any Bash/PowerShell command that does not run `dt-job.ps1`, `read-evidence.ps1`, `write-build-state.ps1`, or `git status|log|rev-parse`. An open irreversible step (`dt-job irreversible -Action begin`) defers the hard-limit denials. The deny reason names the next step.
- `coordinator-posttooluse.ps1` adds the context line as additional context when the state is `checkpoint` or `rotate`, and stays silent when it is `ok`.
- `settings-snippet.json` is the `hooks` block to merge into a Claude settings file.

A session counts as a coordinator when `DT_BUILD_COORDINATOR_ID` is set, or when its `session_id` matches a session recorded in a registered run's `coordinator.lease` or `context-baseline.json`. Every other session is left alone, and any error inside a hook allows the call.

## Placeholder

`__DT_BUILD_HOOKS_DIR__` in `settings-snippet.json` stands for the absolute path of this `hooks` folder, written with forward slashes (for example `D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/skills/dt-build/hooks`). Replace every occurrence before merging. `${CLAUDE_PLUGIN_ROOT}` is deliberately not used.

`launch-managed-coordinator.ps1` does this replacement itself for managed Claude coordinators: it writes `coordinator-settings.json` into the run folder with the real path and passes it with `--settings`. Interactive sessions get the hooks only once the snippet is merged into the live settings file at adoption.
