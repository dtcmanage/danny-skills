# dt-build coordinator hooks

Claude Code hooks that enforce the dt-build context limit at the tool call. They ship as files only and are installed at adoption, never before.

- `coordinator-pretooluse.ps1` denies, in a dt-build coordinator session only: a Read of a file over 400 lines without `offset`/`limit`, image Reads (png, jpg, jpeg, gif, bmp, webp), and CronCreate. Past the hard context limit it also denies Read, Grep, Glob, WebFetch, WebSearch, Agent, Task, NotebookEdit, and any Bash/PowerShell command with a segment (split on newlines, `;`, `&&`, `||`, `|`, `&`) that is not `pwsh`/`powershell -File`, or a `&`/`.` call, of `dt-job.ps1`, `read-evidence.ps1`, or `write-build-state.ps1`, or `git status|log|rev-parse`. A script name used as an argument or in a comment does not count. An irreversible step (`dt-job irreversible -Action begin`) defers the hard-limit denials only while the coordinator that opened it holds the lease. The deny reason names the next step.
- `coordinator-posttooluse.ps1` adds the context line as additional context when the state is `checkpoint` or `rotate`, and stays silent when it is `ok`. After a shell call that ran `dt-job mark-bootstrap`, it records this session's own `session_id` and transcript in `context-baseline.json` for that coordinator, replacing any transcript `mark-bootstrap` discovered.
- `settings-snippet.json` is the `hooks` block to merge into a Claude settings file.

A session counts as a coordinator when `DT_BUILD_COORDINATOR_ID` is set, or when its `session_id` matches a session recorded in a registered run's `coordinator.lease` or `context-baseline.json`. A transcript `mark-bootstrap` discovered by cwd never identifies a coordinator session. Every other session is left alone, and any error inside a hook allows the call. With `DT_BUILD_COORDINATOR_ID` unset and no registered run, both hooks exit before loading any dt-build script.

## Placeholder

`__DT_BUILD_HOOKS_DIR__` in `settings-snippet.json` stands for the absolute path of this `hooks` folder, written with forward slashes (for example `D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/skills/dt-build/hooks`). Replace every occurrence before merging. `${CLAUDE_PLUGIN_ROOT}` is deliberately not used.

`launch-managed-coordinator.ps1` does this replacement itself for managed Claude coordinators: it writes `coordinator-settings.json` into the run folder with the real path and passes it with `--settings`. Interactive sessions get the hooks only once the snippet is merged into the live settings file at adoption.

## Live settings file (adoption target)

Checked 2026-10-10 (ET), read-only, on Danny's Windows PC:

- `CLAUDE_CONFIG_DIR` is set to `D:\Claude` at User scope, so Claude Code reads its user settings from `D:\Claude\settings.json` and writes transcripts under `D:\Claude\projects\`. That file is the live one. It has no `hooks` key today.
- `C:\Users\Danny\.claude\settings.json` holds a SessionStart hook that runs `D:\Claude\_system-tools\workspace-sync\pull-workspace.ps1`, which logs `START session-start-pull` to `D:\Claude\_system-tools\workspace-sync\sync.log` on every run. The log, covering 2026-10-02 through 2026-10-10 with 127 full-sync runs and many Claude sessions, holds no session-start entry. That file is not loaded.

Adoption target: merge the `hooks` block from `settings-snippet.json` into `D:\Claude\settings.json`. Do not edit `C:\Users\Danny\.claude\settings.json` for these hooks.
