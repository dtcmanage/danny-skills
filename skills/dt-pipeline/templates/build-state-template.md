# Build State — __PROJECT_NAME__

<!--
  Canonical `_build-state.md` shape. This template is the single source of truth for the
  pipeline checkpoint file — every writer (dt-pipeline, dt-build) rewrites the WHOLE file
  from this template at every phase boundary and milestone completion. Never append, never
  partial-edit: a crash mid-write must leave either the old complete file or the new one.
  Replace every __TOKEN__; write `none` when a field has no value yet.
-->

status: __STATUS__
<!-- IN_PROGRESS | BLOCKED | COMPLETE -->
phase: __PHASE__
<!-- intake | plan | review | roadmap | build | done -->
project: __PROJECT_NAME__
planning_folder: __PLANNING_FOLDER__
updated_utc: __UPDATED_UTC__

## Artifacts
plan_path: __PLAN_PATH__
design_path: __DESIGN_PATH__
roadmap_path: __ROADMAP_PATH__
run_id: __RUN_ID__
build_branch: __BUILD_BRANCH__

## Progress
current_milestone: __CURRENT_MILESTONE__

### Completed
<!-- One line per completed phase or milestone, oldest first:
     - plan — plan-draft.md authored
     - review — design-final-<slug>.md converged (N rounds)
     - M01 <name> — PASS <commit-sha>
     Write `- none` when nothing is complete yet. -->
__COMPLETED_LIST__

### In flight
<!-- What is being worked on RIGHT NOW (subagent + milestone/chunk), or `- none`. -->
__IN_FLIGHT__

## Git
last_commit_sha: __LAST_COMMIT_SHA__
<!-- Newest commit on the build/feature branch; `none` before the build phase. -->
uncommitted_artifacts:
<!-- One line per file that exists on disk but is not yet committed, or `- none`. -->
__UNCOMMITTED_ARTIFACTS__

## Next step
<!-- The single concrete action a resuming session takes first. Imperative, one or two lines. -->
__NEXT_STEP__
