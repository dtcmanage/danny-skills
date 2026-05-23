# Codex Prompt Assembly Byte Contract

Execution parity contract:
- Prompt assembly is executed only via `skills/dt-build/scripts/assemble-codex-prompt.ps1`.
- Envelope boundaries are delegated to repo-level `scripts/wrap-prompt-envelope.ps1`; dt-build does not reimplement wrapper logic.
- Codex prompt verification is executed only via `skills/dt-build/scripts/verify-codex-prompt.ps1`.

Codex verify gate requires:
- stable identity header
- allowed-character scan
- delimiter balance
- payload integrity check against manifest-bound data

Any verification failure blocks spawn.
