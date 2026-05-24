---
name: dt-terminal-format-profile
description: "Set or update a repo/workspace VS Code terminal color profile by writing `.vscode/settings.json`. Trigger when Danny says things like 'make this repo color blue', 'set this workspace terminal background dark red', 'give this repo a different red', or 'change the terminal color for this folder'. Use for deterministic, workspace-local terminal theming only. Do NOT use for Codex/Claude transcript theming or global VS Code appearance."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(pwsh:*) Read Write Edit"
compatibility: "Cowork, Claude Code CLI, or Codex CLI; requires danny-skills repo present."
metadata:
  version: 1.1.0
  changelog: "Added paired repo-plus-workstation-root writes with deterministic companion shade derivation, while preserving single-target local `.vscode/settings.json` terminal palette updates."
---

# Terminal Format Profile

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

Use this skill to assign a repo-local or workspace-local VS Code terminal background color without touching global settings.

## When this fires

Trigger when Danny wants a repo or workspace to have its own VS Code terminal color, including requests like:
- "make this repo color blue"
- "set this workspace terminal background dark red"
- "give this folder a different shade of red"
- "change the terminal color for this repo"

Do NOT fire for:
- Codex transcript theming or assistant-vs-user message styling
- Claude transcript theming
- global VS Code appearance changes

## Procedure

1. Infer the target scope directly from the request:
- `repo` or `project` means the nearest ancestor containing `.git`
- `workspace`, `workstation`, or `folder` means the current working directory
- an explicit path wins over both
- if no scope word is given, prefer the nearest git root; otherwise use the current directory

2. Infer the requested color:
- accept a named preset like `blue`, `navy`, `dark red`, `oxblood`, `burgundy`, `teal`, `green`, `purple`, `gold`, `slate`, `black`
- accept a hex color like `#1d4ed8`
- if Danny asks for "a different shade" of a family, choose the nearest preset in that family and say which one you picked

3. Run this skill's script:
- `pwsh -File scripts/set-terminal-workspace-color.ps1 -Color <color> -Scope <repo|workspace|path> [-TargetPath <path>]`
- when Danny wants a repo color plus a related workstation-root shade, use:
  `pwsh -File scripts/set-terminal-workspace-color.ps1 -Color <color> -Scope repo -AlsoSetWorkstationRoot -WorkstationVariant lighter`
- if the workstation companion color must be explicit rather than derived, pass:
  `-WorkstationColor <color-or-hex>`

4. Report only the local result:
- the resolved target root
- the written `.vscode/settings.json` path
- the applied palette name
- if companion mode ran, also report the workstation root, its settings path, and the derived or explicit workstation palette
- remind Danny to reopen the terminal in that workspace

## Guardrails

- Never touch user-level VS Code settings for this skill.
- Never claim this changes Codex or Claude transcript theming; it only changes the workspace terminal profile.
- Preserve unrelated keys in an existing `.vscode/settings.json`.
- Create `.vscode/settings.json` if it does not exist.
- If `repo` scope is requested and no `.git` ancestor exists, stop and say so plainly.
- If `-AlsoSetWorkstationRoot` is used, derive the workstation root as the resolved repo root's parent directory. An explicit `-WorkstationColor` overrides the derived variant.
- Keep the write local to the requested target; do not widen to sibling folders.
