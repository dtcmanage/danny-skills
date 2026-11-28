# Skill propagation gate

8. Skill propagation gate (danny-skills builds only):
- Fires only when the built repo is the `danny-skills` plugin repo. Detect by reading `<repo>/.claude-plugin/plugin.json` and confirming `name == "danny-skills"` and a top-level `skills/` directory exists. Skip the gate otherwise.
- Detect new skill folders added by this build run:
  - Resolve the merge base: `git merge-base <merge_target> <build_branch>`.
  - List added skill folders: `git diff --name-only --diff-filter=A -M <merge_base> <build_branch> -- skills/`, then keep paths matching `^skills/[^/]+/` and reduce to unique top-level skill names.
  - A folder rename (old removed, new added) surfaces as a new skill on the new side and an orphan in the propagation report; the build does not auto-clean the orphan.
  - Do NOT fire for SKILL.md-only or content-only edits where the skill folder name is unchanged.
- For each new skill name, invoke the repo-level propagator:
  `pwsh -NoProfile -File <repo>/scripts/verify-skill-junctions.ps1 -RepoRoot <repo> -NewSkills <names...> -Create -Json`
  It reconciles the four skill-link surfaces named in its header (symlinks on Linux, junctions on Windows). Cowork is auto-propagated by its whole-folder junction and is not touched here.
- Run this before marking the final checkpoint COMPLETE. Hard fail finalization when any of these surface in the script output:
  - any row with status `missing`, `wrong_target`, `create_failed`, or `collision_not_junction`,
  - any entry in `setup_gaps` (a target parent directory does not exist; never auto-create it),
  - any entry in `orphans` introduced by this run.
- Append the full propagation JSON to the build-final summary (the always-on record); when Danny has asked for the `build-run-review.html` companion (step 6.5), also surface a "Skill Propagation" panel in it listing per-(skill, location) status, any setup gaps, and any orphans.
- The same script is callable ad-hoc for retroactive sweeps with no `-NewSkills` (scans all skills in the repo) and without `-Create` (report-only).
- Before COMPLETE, run repo-level `<danny-skills>/scripts/verify-versioning-policy.ps1 -BaseRef <merge_target> -Json`.
  Any error in skill SemVer, current-first changelogs, manifest agreement, changed-skill bumps, or the plugin
  release bump blocks finalization. Persist the validator JSON beside the propagation evidence.

