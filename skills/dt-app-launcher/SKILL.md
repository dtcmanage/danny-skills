---
name: dt-app-launcher
description: "Create or repair deterministic local GUI launchers for repo apps. Trigger on /dt-app-launcher, 'create an app launcher', 'make this standalone', 'add desktop/start menu shortcut', or when a local HTML/dashboard/server app needs a standalone window. Do NOT use for VS Code terminal colors or normal dev-server debugging."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(pwsh:*) Read Write Edit"
compatibility: "Cowork, Claude Code CLI, or Codex CLI on Windows; requires danny-skills repo present."
metadata:
  version: 0.3.0
  changelog: "Extracted launcher verification to scripts/verify-launcher.ps1: deterministic pass/fail report on manifest files, shortcut .lnk targets (edge_static vs python_gui), TCP listener, and Edge hardening-flag presence. SKILL.md step 4 now invokes the script instead of asking the AI to interpret process command lines and shortcut targets by hand."
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

3. Select launcher mode, then run the scaffolder from this skill:

- `edge_static` mode: static/dashboards served locally and opened in hardened Edge app-mode.
- `python_gui` mode: Python apps that already implement their own GUI window behavior from `main.py` (for example File Sorter). This mode creates shortcuts that target `pythonw.exe` directly and do not use `.bat` as shortcut target.

```powershell
pwsh -File skills/dt-app-launcher/scripts/new-app-launcher.ps1 `
  -AppName "<app name>" `
  -TargetPath "<absolute app repo path>" `
  -StaticRoot "<relative or absolute static root>" `
  -EntryFile "<entry html file>" `
  -LauncherMode edge_static `
  -Port <port> `
  -CreateShortcuts
```

Python GUI pattern:

```powershell
pwsh -File skills/dt-app-launcher/scripts/new-app-launcher.ps1 `
  -AppName "<app name>" `
  -TargetPath "<absolute app repo path>" `
  -StaticRoot "." `
  -EntryFile "<python entry file again; required field>" `
  -LauncherMode python_gui `
  -PythonEntry "<python entry file such as main.py>" `
  -Port <app port> `
  -CreateShortcuts
```

Optional parameters:
- `-Slug <slug>` to force launcher filenames.
- `-BuildCommand "<command>"` to run before serving.
- `-AllowedRoot <path>` to enforce a static root containment check.
- `-NoShortcuts` to write scripts only.
- `-PythonArgs "<args>"` to pass optional args in `python_gui` mode.

4. Verify the generated launcher:
- Run the generated `scripts\stop-<slug>.ps1` first to clear stale state.
- Run `scripts\start-<slug>.ps1 -SkipBuild` if the static artifact already exists; otherwise run without `-SkipBuild`.
- Run the verifier with `-CheckRunning` to confirm the running process matches the contract:

  ```powershell
  pwsh -NoProfile -File skills/dt-app-launcher/scripts/verify-launcher.ps1 `
    -ManifestPath "<absolute path to <slug>-launcher.json>" `
    -CheckRunning -Json
  ```

  The script reads the manifest and runs a fixed checklist: manifest + helper script files exist; Desktop + Start Menu `.lnk` shortcuts exist and target the right exe (powershell.exe wrapping start-`<slug>`.ps1 for `edge_static`; `pythonw.exe` directly for `python_gui`, never a `.bat` and never the WindowsApps shim); a TCP listener exists on the manifest port; and (for `edge_static`) an `msedge.exe` process exists carrying `--app=`, `--user-data-dir=` containing the slug, `--disable-sync`, `--disable-extensions`, and `--no-first-run`. The JSON output is `{ pass, checks: [{ name, status, detail }] }` — surface any `fail` rows directly without re-interpreting raw process command lines.

- Run the generated stop script and re-run the verifier without `-CheckRunning` to confirm the listener is gone and the install-time artifacts remain.

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

For `python_gui` mode, the generated shortcut script must:
- resolve a real `pythonw.exe` (not WindowsApps shim)
- set `.lnk` TargetPath to `pythonw.exe`
- set `.lnk` Arguments to the configured Python entrypoint
- set WorkingDirectory to the target repo root
- never target `.bat` or `powershell.exe` for the user-facing shortcut

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
- For Python GUI apps, do not point shortcuts to `.bat` or `powershell.exe`; point directly to `pythonw.exe`.
- Quote or backtick paths with spaces in all final output.
- If a pinned taskbar shortcut could still point at an old target, say that explicitly and tell Danny to unpin the stale one.
