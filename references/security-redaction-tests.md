# Security Redaction Tests — Fixture Corpus

The acceptance corpus for the secret-pattern redaction module (`scripts/security/redact-secrets.ps1`,
Control 4 in `references/security-posture.md`). Every fixture below is **synthetic** — fake, format-valid
strings authored for testing. None is a real credential.

## Pass criteria

Run every fixture through `Invoke-SecretRedaction`:
- **Known-secret leaks = 0.** Every MUST-REDACT fixture must be modified (the matched secret masked). A
  MUST-REDACT fixture returned unchanged is a leak. Zero leaks tolerated.
- **False-positive rate < 5%.** A MUST-NOT-REDACT fixture must be returned byte-for-byte unchanged. A
  changed safe fixture is a false positive. Fewer than 5% of safe fixtures may change. (With the corpus
  below, that floor rounds to zero allowed false positives.)
- **Cross-consumer identity.** Every consumer that runs this corpus through its own log/HTML path must
  produce identical redacted output (enforced from the phase where each consumer ships).

## Harness contract

A fixture is one non-blank line inside the marked block. A literal `\n` inside a fixture is expanded to a
real newline before redaction (this is how multiline cases are represented in a line-based corpus). Lines
that are blank or HTML comments are ignored. The patterns the module must cover: GitHub PAT `ghp_*`,
generic `pat_*`, Slack bot token `xoxb-*`, JWT-shaped `eyJ<base64>.<base64>.<base64>`, and Azure SAS query
strings carrying `sig=` (with `sv=`). Matching is pattern-specific, never generic high-entropy matching —
that is what keeps the false-positive rate at zero on the safe set.

## MUST-REDACT (each must be masked)

<!-- MUST-REDACT-BEGIN -->
ghp_AbCdEf0123456789AbCdEf0123456789AbCd
pat_live_0123456789abcdefghijABCDEF
xoxb-SYNTHETIC-FIXTURE-ALPHA-DO-NOT-USE
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
https://acct.blob.core.windows.net/cont/file.txt?sv=2022-11-02&ss=b&srt=co&sp=rwdlac&se=2025-12-31T23:59:59Z&st=2025-01-01T00:00:00Z&spr=https&sig=AbCd1234EfGh5678IjKlMnOpQrStUvWx
Authorization: Bearer ghp_ZzZzYyYyXxXx0011223344556677889900AbCd trailing text
slack_token = xoxb-SYNTHETIC-FIXTURE-BETA-DO-NOT-USE
prefix line is fine\nline two leaks pat_test_9988776655AbCdEfGhIjKl\nline three is fine
callback?sv=2021-08-06&sig=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MGFiY2RlZg
download?sv=2020-08-04&ss=b&srt=o&sp=r&sig=Ab%2BcD%2FeF%3DgHiJkLmNoPqRsTuV1234
<!-- MUST-REDACT-END -->

## MUST-NOT-REDACT (each must pass through unchanged)

<!-- MUST-NOT-REDACT-BEGIN -->
this is a perfectly ordinary sentence describing the design, with no secrets in it at all
the milestone commit sha is 3a2c68dae50d9caebd4bd456a7b118f59b766101 and that is public history
patently obvious that pat is just an English word prefix here, not a token
the ghpost of christmas past is not ghp_ anything real
base64 of plain text is safe: VGhpcyBpcyBub3QgYSBzZWNyZXQsIGp1c3Qgc29tZSB0ZXh0Lg==
a long hex digest like a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4 is a file hash, keep it
function names like computeXoxbHash and parsePatList must not trip the matcher
mermaid-10.9.3.min.js is the vendored asset filename
JSON Web Tokens are abbreviated JWT but the acronym itself is not an eyJ-prefixed value
a uuid like 550e8400-e29b-41d4-a716-446655440000 is an identifier, not a secret
first line of a normal note\nsecond line continues the note\nthird line ends it
<!-- MUST-NOT-REDACT-END -->
