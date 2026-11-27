# Codex Prompt Assembly Byte Contract

Execution parity contract:
- Prompt assembly is executed only via `<skill>/scripts/assemble-codex-prompt.ps1`.
- Envelope boundaries are delegated to repo-level `<danny-skills>/scripts/wrap-prompt-envelope.ps1`; dt-build does not reimplement wrapper logic.
- Codex prompt verification is executed only via `<skill>/scripts/verify-codex-prompt.ps1`.
- Verified prompts are executed only via `<skill>/scripts/invoke-codex-chunk.ps1`; the wrapper
  requires a one-line selection reason, resolves the live model tier, pins effort, passes stdin, redacts
  logs, and writes the reason plus canonical disclosure line to provenance JSON.

Codex verify gate requires:
- stable identity header
- allowed-character scan
- delimiter balance
- payload integrity check against manifest-bound data

Any verification failure blocks spawn.

`-RequiredEntitlements` accepts an array or comma-separated text through `pwsh -File` and trims names.
`-PreambleText` supplies inline framing; `-PreamblePath` reads a file and takes precedence if both are
supplied. Both are optional; omit both for the built-in worker preamble. Neither replaces identity,
envelopes or the output contract. Both wrappers add a missing attempt header from `-Attempt`, and
reject conflicting, malformed or ambiguous existing headers without hiding them.
