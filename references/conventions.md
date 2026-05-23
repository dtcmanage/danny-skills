# danny-skills Conventions

Shared conventions every pipeline skill follows. Repo-level reference; read it when authoring or
editing any skill, script, or reference file in this repo.

## Path resolution — SKILL.md-anchored, never `pwd`

Cross-skill references break the moment a script trusts the current working directory. A skill can be
invoked from anywhere; `pwd` is whatever the user happened to be standing in. Every script therefore
resolves its paths from the SKILL.md location, not the cwd.

### The junction reparse trap

All three surfaces (CLI/Agent-SDK, Cowork, Codex) load skills through **per-skill directory junctions**
— e.g. `~\.agents\skills\dt-plan` is a junction whose target is `danny-skills\skills\dt-plan`. A naive
`..`/`..` walk out of a script under such a junction stays *inside the junction tree*
(`~\.agents\skills\`), never reaching the real repo. Repo-level `references/`, `scripts/`, and `assets/`
live only under the real `danny-skills\` root, so the walk-up MUST first resolve the skill folder through
its reparse point to the real target, then climb to the repo root.

Canonical PowerShell pattern (PowerShell 7+):

```powershell
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir                        # the skill's SKILL.md folder

# Resolve the skill folder through any junction/symlink to its REAL target before
# walking up. ResolveLinkTarget($true) returns the final target for a reparse point,
# or $null when the path is not a link (i.e. the skill is being run directly inside
# the repo working tree) -- in which case keep $SkillRoot as-is.
$resolved = (Get-Item -LiteralPath $SkillRoot).ResolveLinkTarget($true)
if ($resolved) { $SkillRoot = $resolved.FullName }

$RepoRoot    = Split-Path -Parent (Split-Path -Parent $SkillRoot) # danny-skills/
$RepoRefs    = Join-Path $RepoRoot 'references'
$RepoScripts = Join-Path $RepoRoot 'scripts'
```

Verified 2026-05-21 against a live junction: from `~\.agents\skills\<skill>\scripts\` the pattern resolves
to `danny-skills\references`, and from inside the repo working tree the `$null` fallback keeps the literal
path. Every repo-level script must use this reparse-resolving form, never a bare `..`/`..` walk.

Rules:
- A script in `skills/<name>/scripts/` reaches its own skill's files via `$SkillRoot` (post-resolution),
  and repo-level shared files via `$RepoRoot`.
- A SKILL.md references its own per-skill files first (relative to the skill folder); cross-skill and
  repo-level references use repo-relative paths anchored on the SKILL.md location.
- Never hardcode an absolute path, and never assume the cwd is the repo root or the skill folder.

## Frontmatter fields

Every SKILL.md carries YAML frontmatter. Fields used across the pipeline:

| Field | Purpose |
| :-- | :-- |
| `name` | The skill's invocation name (kebab-case, matches the folder). What `/<name>` and the model match against. |
| `description` | One-line trigger spec: when to use the skill and when not to. Must be valid YAML (quote it; an unquoted `: ` is parsed as a nested mapping by Codex's stricter loader) and at most 1024 characters. |
| `disable-model-invocation` | `true` when the skill must only run on an explicit `/<name>` or direct request, never auto-fired by the model from context. |
| `user-invocable` | `true` when the skill is exposed as a `/<name>` slash command. |
| `allowed-tools` | The tool allowlist the skill's orchestrator may use, constraining what it can spawn (e.g. `"Bash(codex:*) Bash(git:*) Bash(pwsh:*) Read Write Edit AskUserQuestion"`). |
| `compatibility` | Where the skill runs (e.g. `"Cowork or Claude Code CLI; requires danny-skills repo present."`). |
| `metadata.version` | The skill's own semver, independent of the plugin manifest version. Bumped on any behavioral change to the skill. |
| `metadata.changelog` | Per-skill change log. Tagged entries (e.g. `phase-4-dt-review`) record what changed at each release. |

The plugin manifest version (`.claude-plugin/plugin.json` + `marketplace.json`) is separate from any
skill's `metadata.version`: the plugin bumps on milestone drops; a skill bumps when its own behavior changes.

## The `_log.md` friction-note convention

Each skill folder carries a `_log.md` — an append-only friction log, one line per invocation that hit
friction. Format: a single line capturing what tripped, e.g. `2026-05-21 dt-review: verdict parse missed a
lowercase confidence token`. These notes are the raw material `dt-tune` reads when proposing a SKILL.md
amendment.

Rules:
- One line per friction event; include date, skill name, and the concrete failure/friction.
- Never rewrite, reorder, or delete historical lines in `_log.md`.
- Retention: when `_log.md` exceeds 200 lines, move the oldest lines into `_log-archive.md` (append-only),
  preserving order, and keep the newest 100 lines in `_log.md`.

Session-end stop-hook recommendation:
- If any `_log.md` received a new friction line in the session, suggest `/dt-tune <skill>` for each
  implicated skill before ending the session.
