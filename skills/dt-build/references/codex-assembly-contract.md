# Codex Prompt Assembly Byte Contract

Phase 7A note:
- Prompt-envelope assembly is delegated to repo-level `scripts/wrap-prompt-envelope.ps1`.
- dt-build does not reimplement wrapper logic locally.

Codex verify gate requires:
- stable identity header
- allowed-character scan
- delimiter balance
- payload integrity check against manifest-bound data

Any verification failure blocks spawn.
