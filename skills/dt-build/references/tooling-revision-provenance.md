# Tooling and runtime file provenance

Runs own the acceptance decision. These read-only proofs permit record-and-continue only for an already authorized dependency class and transition. They never grant execution authority, change approvals or boundaries, or update a run's pin themselves.

## Published tooling and workspace guides

Invoke `scripts/resolve-tooling-revision.ps1 -Path <installed-file> -Json` for danny-skills tooling. The default repository is the source danny-skills checkout, including when invoked through a skill junction. For a workspace guide use `-RepoRoot D:/Claude`; for example:

```powershell
cd "<danny-skills checkout>"
pwsh -NoProfile -File skills/dt-build/scripts/resolve-tooling-revision.ps1 -Path D:/Claude/_Claude-Workspace/00_Resources/ops-conventions.md -RepoRoot D:/Claude -Json
```

Files within the selected repository infer their repository-relative path. Installed `dt-build/scripts` copies retain the canonical tooling path inference. For an external copy, supply `-RepoRelativePath <repo-path>`.

The helper compares exact bytes, including line endings, with the selected repository's local `origin/main` history. `ON_MAIN` means a matching blob exists at that path in a commit reachable from that ref; it can be historical, not just the head version. `is_ref_head` states whether the head blob matches. The helper never fetches unless `-Fetch` is explicitly passed; append-only checks never touch git. A local remote-tracking ref is a snapshot, not proof of the current remote state.

JSON records `repo_root`, `repo_relative_path`, `ref`, `ref_head`, `ref_commit_date` (time of the checked head), `commit`, `commit_date` (newest matching path revision), size, SHA256, blob id and `is_ref_head`. Dates use Eastern time with a numeric offset.

A run may accept `ON_MAIN` (exit 0) automatically for published tooling and workspace guides when its existing contract allows published revisions from that repository/ref, including historical revisions if allowed. Record the old/new size and SHA256 plus all provenance fields. If the run requires the latest version, require `is_ref_head`; if it requires a fresher ref snapshot than available, stop and obtain that proof outside this helper. Stop for `NOT_ON_MAIN` (exit 3), an unexpected repository/ref, an ineligible file, or any authority/boundary conflict. Guide provenance never authorizes a newly described operation.

## Append-only machine runtime files

Capture the pinned bytes when creating the pin. Invoke the same helper with `-Path`, `-PinnedSha256`, exactly one of `-PinnedCopyPath <saved-bytes>` or `-PinnedLines <saved-lines-file>`, and one or more `-ProtectedPattern` regexes selecting every row the run depends on. Patterns are case-sensitive .NET regexes, each bounded by a two-second match timeout. For multiple patterns, invoke the script from PowerShell with an array:

```powershell
cd "<danny-skills checkout>"
& ./skills/dt-build/scripts/resolve-tooling-revision.ps1 -Path C:/Users/Danny/.ssh/known_hosts -PinnedSha256 <64-hex-digest> -PinnedCopyPath <saved-copy> -ProtectedPattern @('^192\.168\.71\.29 ', '^other-required-host ') -Json
```

Inputs must be UTF-8 (strict decoding, no replacement characters). Hash and byte-prefix checks include any BOM. A pinned copy must match the pinned SHA256 or exit 2. A pinned-lines file may contain selected exact rows for diagnostics, but it proves a full prefix only if its exact bytes also match the pinned hash. Without full original bytes, a changed file returns `CHANGED` with `pinned_lines_do_not_prove_full_byte_prefix`; selected rows alone cannot prove append-only behavior. An unchanged current hash still proves `UNCHANGED`.

| Verdict | Required proof | Exit |
| :-- | :-- | :-- |
| `UNCHANGED` | Current SHA256 equals the pin. | 0 |
| `APPEND_ONLY` | Authenticated pinned bytes are an exact prefix, supplying only an absent final LF or CRLF if needed; protected row contents and multiplicities are identical. | 0 |
| `CHANGED` | Any other content transition or insufficient full-prefix evidence. | 3 |
| Error | Missing/mismatched copy, malformed inputs/regex, decoding, IO or git failure. | 2 |

No existing line ending is normalized: CRLF-to-LF and LF-to-CRLF rewrites are `CHANGED`. A final unterminated row must end before appended content; extending that row is `CHANGED`. Adding a duplicate protected row also fails. Protected rows compare verbatim, case-sensitively, as a multiset, with only LF/CRLF row delimiters excluded.

JSON includes `pinned_sha256`, new `sha256` and `bytes`, `prefix_verified`, `reason`, `appended_line_count` and `appended_hosts` (each appended row's first token). `protected_removed` and `protected_added` list first tokens and exact-row SHA256 hashes, preserving duplicates. An edit appears as removal of the old hash plus addition of the new hash; this identifies changed rows without returning their contents. No key material is emitted (stronger than the 16-character maximum). Counts describe appended rows only when a prefix is verified; zero does not imply no changes for a rejected prefix.

A run may record and continue for `UNCHANGED` or `APPEND_ONLY` only for a declared append-only machine file whose protected patterns cover all rows it relies on. Record old/new size and SHA256, baseline locator/hash, the protected patterns, verdict, prefix evidence and redacted append/row audit. Recheck that the live bytes still match the result hash before accepting/updating the pin; the proof describes the captured snapshot. Preserve the original pinned evidence or save the newly accepted full snapshot for the next comparison.

Stop for `CHANGED`: protected edits/removals/additions, whole-file rewrites, non-prefix changes, and insufficient pinned evidence all require the run's operator decision. Exit 2 proves nothing: correct the error and retry. Never auto-accept regex changes, missing baseline evidence, or a changed protected host key by treating them as harmless runtime drift.
