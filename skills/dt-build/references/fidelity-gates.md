# Plan-to-build fidelity

At intake, run the canonical dt-roadmap validator including its design coverage gate. Read
`skills/dt-roadmap/references/design-coverage.md` for requirement units and shared split-build tables.
Every requirement must belong to exactly one build milestone or an owned out-of-build row.

## External API clients (FS-126)

Before dispatching a milestone that adds or changes a named external API client, its brief must cite
the saved redacted raw auth and **every called endpoint** sample in `design/api-samples/<service>/`.
Include these files in the reference pack/entitlements. Build client fixtures from those samples,
never invented response shapes. Preserve null/empty/paginated variants where observed. Missing samples
are a contract revision/environment gap to resolve before building, not an invitation to fabricate.

Require the design and roadmap to carry `## External API Contracts` with one row per affected
milestone/service. The producer carries this section verbatim. Paths are relative to the roadmap;
when relocating a roadmap, adjust paths. Commands run from the milestone working tree.

| milestone-id | service | samples | credentials | auth-check | read-check | residual |
| --- | --- | --- | --- | --- | --- | --- |
| M01 | openalt | api-samples/openalt/auth.json; api-samples/openalt/search.json | available | `python scripts/check_openalt.py --auth-only` | `python scripts/check_openalt.py --read-only --validate-used-fields` | - |

The read-only checker authenticates and performs one representative read against the actual service;
validate the fields, nesting and types used by the client code. Never send messages, mutate business
records or trigger real alerts. The auth exchange itself may issue a token. Redact persisted evidence.
Run fresh independent semantic verification for every external client milestone. The verifier checks
that every added/changed external client has a row, that its fixtures
derive from the cited samples, and that the live checker really validates the fields the code uses.
Declaration is reviewed against the diff; the gate cannot infer client semantics or prove a probe is
live from a command name.

`verify-milestone-acceptance.ps1 -RunTests` checks sample presence and executes both named live commands
before acceptance, in addition to the ordinary verification manifest. Any failure blocks acceptance.
When credentials are unavailable, set `credentials` to `unavailable` and name a residual in `residual`
with the attempted credential source, owner and recheck gate. The result records
`API_CREDENTIALS_UNAVAILABLE` and blocks clean acceptance; it never silently passes. An operator-owned
exception follows the existing explicit downgrade procedure and remains visible in the final ledger.

## Close-out / switch-on

The final ledger renders the shared out-of-build checklist in both Markdown and HTML. Relay it in
the go-live handoff; the owning human/session completes each item with evidence before switch-on.
Keep unavailable API checks and other named residuals visible alongside it. Never equate a repo's
milestone PASS with completion of cross-workstation/manual requirements.
