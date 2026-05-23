# Artifact Integrity and Security Contract

Phase 7A intake contract:
- Reference-pack files are immutable after write.
- `reference-manifest.md` is the single source of file path/hash/size truth.
- Spawn preflight resolves logical entitlements through the manifest and fails closed on mismatch.
- Logs are metadata-only; no credential/raw prompt payload capture.
- Secret redaction uses repo-level `scripts/security/redact-secrets.ps1`.

Codex lane integrity:
- Prompt assembly and verify-gate rules are governed by `references/codex-assembly-contract.md`.
