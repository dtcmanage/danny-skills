# Artifact Integrity and Security Contract

Intake contract (7A):
- Reference-pack files are immutable after write.
- `reference-manifest.md` is the single source of file path/hash/size truth.
- Spawn preflight resolves logical entitlements through the manifest and fails closed on mismatch.
- Logs are metadata-only; no credential/raw prompt payload capture.
- Secret redaction uses repo-level `scripts/security/redact-secrets.ps1`.

Execution contract (7B):
- Codex prompt assembly is executed by `scripts/assemble-codex-prompt.ps1`.
- Codex prompt verify gate is executed by `scripts/verify-codex-prompt.ps1`.
- Any verify-gate failure blocks Codex spawn.
