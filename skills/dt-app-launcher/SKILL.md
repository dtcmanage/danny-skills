---
name: dt-app-launcher
description: "Create or repair deterministic local GUI launchers for repo apps. Trigger on /dt-app-launcher, 'create an app launcher', 'make this standalone', 'add desktop/start menu shortcut', or when a local HTML/dashboard/server app needs a standalone window. Do NOT use for VS Code terminal colors or normal dev-server debugging."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(pwsh:*) Read Write Edit"
compatibility: "Cowork, Claude Code CLI, or Codex CLI on Windows; requires danny-skills repo present."
metadata:
  version: 0.1.0
  changelog: "Initial deterministic launcher scaffolder with hardened Edge app-mode profile, shortcut, stop script, and smoke-test contract."
---

# App Launcher

Use this skill to create or repair a Windows standalone launcher for a local app so Danny can open it from Desktop or Start Menu without hand-debugging browser profile, shortcut, port, or cleanup behavior.

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

## When this fires

Trigger when Danny asks for any of:
- `/dt-app-launcher`
- "create an app launcher"
- "make this app standalone"
- "make a desktop shortcut"
- "make a Start Menu shortcut"
- "stop opening this in my browser"
- "create a GUI launcher for this local dashboard/app"
- repair of a launcher that opens normal Edge/Chrome tabs, triggers sync/profile onboarding, leaks extensions, or leaves a server process behind

Do NOT fire for:
- VS Code terminal color profiles -- that is `dt-terminal-format-profile`
- ordinary frontend bug investigation without a launcher request
- remote production service launchers
- apps that require an exact OAuth redirect port unless that port is already registered for this app

## Deterministic Procedure

1. Identify the target app:
- Use an explicit path if Danny gave one.
- Otherwise use the current repo root.
- Identify the app name from the request, package name, README title, or repo folder name.
- Identify the static root and entry file:
  - static HTML output: set `-StaticRoot` to the output folder and `-EntryFile` to the HTML file.
  - generated dashboard repo: use the generated artifact folder and dashboard HTML.
  - dev server app: do not scaffold a static launcher unless the app has a built output folder; create a wrapper only after confirming the run command and URL path.

2. Choose a port:
- Use an explicit port if given.
- Otherwise choose a local fixed port that is not reserved.
- Never use File Sorter port `8792`.
- Check current listeners before writing the launcher.

3. Run the scaffolder from this skill:

```powershell
pwsh -File skills/dt-app-launcher/scripts/new-app-launcher.ps1 `
  -AppName "<app name>" `
  -TargetPath "<absolute app repo path>" `
  -StaticRoot "<relative or absolute static root>" `
  -EntryFile "<entry html file>" `
  -Port <port> `
  -CreateShortcuts
```

Optional parameters:
- `-Slug <slug>` to force launcher filenames.
- `-BuildCommand "<command>"` to run before serving.
- `-AllowedRoot <path>` to enforce a static root containment check.
- `-NoShortcuts` to write scripts only.

4. Verify the generated launcher:
- Run the generated `scripts\stop-<slug>.ps1` first to clear stale state.
- Run `scripts\start-<slug>.ps1 -SkipBuild` if the static artifact already exists; otherwise run without `-SkipBuild`.
- Confirm an Edge process exists with:
  - `--app=<local url>`
  - `--user-data-dir=<temp profile containing <slug>>`
  - `--disable-sync`
  - `--disable-extensions`
  - `--no-first-run`
- Confirm the server listens on the requested port.
- Run the generated stop script and confirm the port is clear.

5. Report the result:
- quote or backtick every Windows path, especially paths containing spaces such as `Start Menu`
- include the generated script paths
- include Desktop and Start Menu shortcut paths if created
- include the exact smoke-test result

## Generated Launcher Contract

The scaffolder writes:
- `scripts\node\serve-static-app.js` if missing
- `scripts\start-<slug>.ps1`
- `scripts\stop-<slug>.ps1`
- `scripts\create-<slug>-shortcut.ps1`
- `start-<slug>.bat`
- `<slug>-launcher.json`

The generated start script must:
- serve only the configured static root
- launch Edge in app mode, not normal browser mode
- use a temporary isolated profile
- pre-seed profile preferences to suppress sync/sign-in prompts
- disable sync, extensions, first-run, default-browser checks, and Edge onboarding surfaces
- clean up the server, app window, and temp profile when the app window closes

The generated stop script must:
- stop only windows/processes matching the configured port or temp profile slug
- stop the listener owning the configured port
- never use `$pid` as a loop variable because `$PID` is PowerShell's read-only automatic process id variable

## Guardrails

- Do not open generated HTML with `Start-Process <html path>`; that launches the user's normal browser/profile.
- Do not rely on shell file associations for GUI launchers.
- Do not leave a port listener behind after a smoke test.
- Do not leave the user's normal Edge profile involved in the app launcher.
- Do not create shortcuts that point at a compatibility script if the direct hardened start script exists.
- Quote or backtick paths with spaces in all final output.
- If a pinned taskbar shortcut could still point at an old target, say that explicitly and tell Danny to unpin the stale one.
