# Skill and Plugin Versioning Policy

This is the canonical versioning contract for every skill and shared runtime component in
`danny-skills`. It deliberately supplements the generic upstream skill format: this pack keeps
external changelogs and release metadata because installed plugin copies need a deterministic
cache-buster and an auditable change record.

## Version layers

| Layer | Canonical field | Purpose |
| :-- | :-- | :-- |
| Skill | `skills/<name>/SKILL.md` -> `metadata.version` | SemVer for one skill's behavior and contract. |
| Skill history | `skills/<name>/CHANGELOG.md` | Newest-first record; its first version must equal `metadata.version`. |
| Plugin | `.claude-plugin/plugin.json` -> `version` | One release/cache-buster for the installed pack. |
| Marketplace | `.claude-plugin/marketplace.json` -> `metadata.version` and `plugins[0].version` | Must exactly equal the plugin version. |
| Plugin history | `.claude-plugin/plugin.json` -> `metadata.changelog[0]` | Newest release summary; must start with the current plugin version. |

`metadata.changelog` inside `SKILL.md` is not authoritative. Existing legacy values may remain until that
skill is next cleaned up, but new or edited skills use a one-line pointer to `CHANGELOG.md`, never duplicate
release history in frontmatter.

Contract fields such as `shape_version`, `schema_version`, and `producer_current_version` version produced
artifacts; they do not replace either the skill or plugin version.

## Skill SemVer

Start a new skill at `0.1.0` and create its changelog in the same change.

| Bump | Use when |
| :-- | :-- |
| Patch | Backward-compatible correction, clarification that changes execution, safer default, model/dependency pin, validation hardening, or internal refactor. |
| Minor | Backward-compatible new trigger, input mode, option, output, integration, or meaningful capability expansion. Before `1.0.0`, use minor for a breaking change. |
| Major | At or after `1.0.0`, an incompatible trigger/input/output/side-effect/security/recovery contract change, removal, rename, or hard cutover. |

Bump a skill when any file under its folder changes except `_log.md`, `_log-archive.md`, or changelog-only
bookkeeping. This intentionally includes instruction wording, metadata, scripts, tests, runtime references,
templates, and assets: even a small wording change can alter model execution. A shared script/reference change
also bumps every skill whose runtime behavior changes because of it.

Use `scripts/bump-skill-version.ps1`; never hand-edit a released skill version or append a release entry
manually. `-Set` is for an intentional forward version only and may never downgrade or repeat a version.

## Plugin SemVer

Make one plugin bump per coherent release, after every affected skill has its final version:

- Patch: normal compatible skill/shared-runtime fixes and improvements.
- Minor: add a skill or materially expand the pack's install-time surface.
- Major: incompatible packaging/manifest change, or remove/rename a released skill.

A plugin bump is required when distributable state changes under `skills/`, `scripts/`, `references/`, or
`assets/` (excluding friction logs and changelog-only repair), or when `tools/build-plugin.ps1` changes how
that state is assembled. The package itself is an allowlist of `.claude-plugin/`, `skills/`, `scripts/`,
`references/`, and `assets/`; root work artifacts and friction logs are never shipped. The plugin changelog entry names every changed
skill and its new version, plus material shared-runtime changes. Use `scripts/bump-plugin-version.ps1` once;
it updates all three manifest fields and prepends the release entry.

Every changed shared file under `scripts/`, `references/`, or `assets/` must have an entry in
`references/shared-component-owners.json`. The entry lists directly affected skills (which must receive their
own bumps) and/or a release-summary token for governance/tooling changes. An undeclared shared change blocks
the release; this keeps shared consumer impact explicit instead of relying on reviewer memory.

## Changelog contract

Every skill has `CHANGELOG.md`. Use either of these newest-first shapes consistently within a file:

```markdown
- 1.2.3 (2026-07-12): One-line release summary.
```

```markdown
## 1.2.3

- Release details.
```

The first version record is the current skill version. Do not keep an `Unreleased` section: iterate first,
then bump once at finalization so abandoned attempts do not create phantom versions. Preserve historical
entries; bookkeeping migration may reorder them without inventing missing release claims.

## Release transaction

1. Finish and verify the behavioral changes.
2. Bump each affected skill once with `scripts/bump-skill-version.ps1`.
3. Bump the plugin once with `scripts/bump-plugin-version.ps1`.
4. Run `scripts/verify-versioning-policy.ps1 -BaseRef <merge-target> -Json`.
5. Run affected tests, then commit. Never mark a build complete or merge while the version gate is red.

On a feature branch, `<merge-target>` is the current local `main`, and `main` must already be an ancestor of
the branch. On clean `main`, packaging resolves and requires the exact prior plugin-release boundary; an
arbitrary older ref or `HEAD` self-comparison is invalid because either can hide an unversioned later change.

The validator is the enforcement authority. It checks all skill versions, shared-policy inheritance,
changelog presence/current-first order, manifest agreement, plugin changelog alignment, changed-skill bumps,
and the release-level plugin bump. New-skill junction propagation remains the separate
`scripts/verify-skill-junctions.ps1` gate.
