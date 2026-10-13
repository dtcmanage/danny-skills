# FS-68: tooling revision provenance

Implemented the read-only `skills/dt-build/scripts/resolve-tooling-revision.ps1` helper and observer guidance in `skills/dt-build/references/managed-resume.md`. The helper works for arbitrary tooling files with an explicit repository-relative path, and infers the path for files directly under installed/source/junctioned dt-build scripts folders. Its default repository root resolves the containing skill junction before walking to danny-skills.

The helper reports exact byte count, SHA256 and Git blob identity without filters, resolves a snapshot of the requested ref (default `origin/main`), and walks that snapshot's path history to select the first/newest matching commit. It emits all requested fields in JSON or a readable list. Commit dates use .NET `Eastern Standard Time`, including the applicable numeric offset. `is_ref_head` compares head bytes; it does not require the matching commit itself to be head. Exits: 0 for ON_MAIN, 3 for NOT_ON_MAIN, 2 for usage/IO errors with a stderr diagnostic. No object, index or working-tree writes occur; no network request occurs unless explicit `-Fetch` opts into `git fetch origin` and its normal ref/object updates.

Observers accept and record ON_MAIN transitions without a fresh hand approval, stop on NOT_ON_MAIN, and correct/retry IO errors before accepting. This is a helper and documented observer contract; it does not modify an existing File Sorter observer or its current run state.

## Verification

| Claim/change | Action | Exact check | Evidence |
| :-- | :-- | :-- | :-- |
| Fixture and live behavior | Run new standalone PowerShell test | Two committed revisions, local edit exit 3, LF/CRLF distinction despite Git attributes, missing file exit 2, explicit arbitrary path, installed copy inference, bad ref, repeated/reverted bytes, ET date and head-byte semantics | Exit 0; 29 assertions passed |
| Read-only default | Fixture checks | Local-edit blob absent from object database after hashing; unchanged status before/after resolution | Assertions passed |
| Junction defaults | Execute helper through temporary skill junction | Same default repository/ref resolution as source copy | Assertions passed; junction unlinked before cleanup |
| Existing regressions | Run only test-dt-build-regressions.ps1 | Existing suite | Exit 0; 225 assertions passed |
| Live current wrapper | Resolve actual worktree wrapper with defaults | ON_MAIN, 44363 bytes, matching c83dc08, is_ref_head=true | New test LIVE JSON |
| Known releases | git cat-file -e followed by raw binary blob extraction and helper resolution | All three specified commits exist locally; byte sizes and full hashes match supplied prefixes | Table below |

Test output is redirected to TEMP and only summaries/live-resolution records are read. Logs: `%TEMP%/fs-68-resolver-test.log` and `%TEMP%/fs-68-regressions.log`. No additional test suites run. The new test remains standalone: the regression script contains its own assertions/fixtures and does not register or enumerate standalone scripts under tests/. It is therefore unchanged.

## Known revisions

All results use local `origin/main` at `1819e2a52999d408d230b30103ad8bc44324a481`. Raw blobs were extracted with `git cat-file blob` through a binary output stream into TEMP files, avoiding PowerShell text conversion and checkout line-ending normalization.

| Known commit | Status | Bytes | SHA256 | Commit date (ET) | is_ref_head |
| :-- | :-- | --: | :-- | :-- | :-- |
| 0637459 | ON_MAIN | 39091 | `4b715fdb90eaf5e1ab19a231fc9b58d48aebb66b7434e7b6f913c2f86b36ba73` | 2026-10-12T03:29:21-04:00 | false |
| 21bd109 | ON_MAIN | 44208 | `e6c7e26789b826bf053440e5e5b5149fdd2de8f7abefcea933bc09a8866f2cec` | 2026-10-13T12:08:17-04:00 | false |
| c83dc08 | ON_MAIN | 44363 | `c3c90a028dd5846beacacdaf3857c971c52dc0eb5d95ac8e18a293f99840cebe` | 2026-10-13T12:22:40-04:00 | true |

- `06374596e265403ee6c7027bc68595fa128e14ec`: blob `74b469eda2c3fa6ad8ca3ea98c5691c9cf02c52c`.
- `21bd109ae02ac9a723d87df42289ece3924d285b`: blob `243e165043298261d88f5d5219af3e8b044499e0`.
- `c83dc08cee8790314cd222dc16050141c1faaeb8`: blob `00788e1ac94f1aaac3faae87b8c8ede17273201c`.

## Scope and close-out

No versions bumped, per task instruction; this is an unreleased feature commit and does not claim to pass the normal release/versioning gate. No fetch, push, merge, deployment, or live-run mutation. Existing untracked `_planning/fs-68-task.txt` and `_planning/fs-68-wrapper.log` are untouched and excluded from the commit. Requested commit message: `feat(dt-build): resolve tooling file revisions to their main commit`.

Session audit: task restrictions and the test-process gate are session-specific; resolver behavior is captured in source, tests and managed-resume guidance. No new durable scaffold fact, preference or term requires capture. No scaffold changes or workspace upload, consistent with the explicit no-push constraint.