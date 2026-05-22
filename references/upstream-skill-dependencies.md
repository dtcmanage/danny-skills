# Upstream Skill Dependencies

Every external skill, MCP server, or vendored asset the pipeline depends on, with its pin and resilience
policy (Control 3 in `references/security-posture.md`). Read it before consuming any external dependency,
and at every phase-gate transition that touches one.

## Governance

- **Owner:** Danny (single approver).
- **Cadence:** monthly check (a ~5-minute calendar reminder) plus a check on any phase-gate transition that
  touches an upstream skill or asset.
- **Drift trigger:** any detected version or SHA256 drift on a pinned dependency blocks the next phase gate
  until reviewed, then either **accepted** (rationale appended to the Drift Log below) or **rolled back**. A
  missed monthly check is not silently skippable -- it propagates as an automatic "drift suspected, review
  required" at the next gate.

## Pinned dependencies

| Dependency | Kind | Trust source | Pinned version / commit | SHA256 | Last-verified danny-skills | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| mermaid.js (vendored) | Vendored asset | jsdelivr npm: `mermaid@10.9.3` `dist/mermaid.min.js` (https://cdn.jsdelivr.net/npm/mermaid@10.9.3/dist/mermaid.min.js) | 10.9.3 | `5a8ec91820bd55afef049068489369910e5d6ce70c8103952f27e29d3e76e8bc` | 0.7.0 | Vendored 2026-05-21 to `assets/visualize/vendored/mermaid-10.9.3.min.js`. The visualize skills load this local path, never a CDN. |
| redact-secrets module | Repo code primitive | `scripts/security/redact-secrets.ps1` | pinned at danny-skills 0.7.0 (Phase 0) | `66378de7d2a362f50d9c46c87aa686aae4b269029bb4103dc8924b75af0050cf` | 0.7.0 | Single canonical secret-redactor. Consumers verify they are calling this revision by SHA256. |
| wrap-prompt-envelope module | Repo code primitive | `scripts/wrap-prompt-envelope.ps1` | pinned at danny-skills 0.7.0 (Phase 0) | `039512fa8ad9eccd44fed6b2693188e709dee36de07509d4945e5f15c853bb6e` | 0.7.0 | Single canonical prompt-injection boundary. |
| `anthropic-skills:xlsx` | External skill | Anthropic skills | to be pinned when first consumed (Phase 6, dt-roadmap) | n/a | - | Produces `milestones.xlsx`. Fallback below. |
| `frontend-design:frontend-design` | External skill | Anthropic skills | to be pinned when first consumed (Phase 2, dt-visualize-plan) | n/a | - | Polished UI mockup. Fallback below. |
| `anthropic-skills:web-artifacts-builder` | External skill | Anthropic skills | to be pinned when first consumed (Phase 2) | n/a | - | Three sketch variants. Fallback below. |
| Mermaid MCP | MCP server | MCP server (server-rendered diagrams) | n/a (server) | n/a | - | Server-rendered diagrams. Vendored mermaid.js is the first-class fallback. |
| Matt Pocock prototype templates | Vendored-at-adapt-time | github.com/mattpocock/skills (MIT) | `b8be62ffacb0118fa3eaa29a0923c87c8c11985c` (`skills/engineering/prototype`) | `SKILL:a653deb65afa2ee8f45c68f6ef4f593147171b386e994c8cccf89292d9ea9d75; LOGIC:da91dc92195c00d5dc33863b8c1a030998025a0f8583ebf2babd770825b7f70c; UI:d76d565149ee50456c5ddc5e29c27fec8737637874fe5c37d970db085a200b27` | 0.7.0 | Adapted in Phase 3 into `skills/dt-prototype/` with attribution file; runtime is local-only (no upstream fetch). |

## Per-dependency fallback table

So a transient outage downgrades to a documented fallback (a conditional gate pass with a debt tag) rather
than stalling a phase gate.

| Upstream | Primary use | Fallback when unavailable | Gate behavior | Debt tag |
| :-- | :-- | :-- | :-- | :-- |
| `anthropic-skills:xlsx` | `milestones.xlsx` from dt-roadmap | Emit `milestones.csv` + a markdown milestone table from the same data | Conditional pass | "regenerate milestones.xlsx before next milestone bump" |
| `frontend-design:frontend-design` | Polished UI mockup in dt-visualize-plan | Substitute `web-artifacts-builder` for polished mode (lower fidelity, unblocked) | Conditional pass; footer flagged | "regenerate polished mockup when frontend-design is reachable" |
| `anthropic-skills:web-artifacts-builder` | Three sketch variants in dt-visualize-plan | Manual single-variant SVG/HTML written by Claude into the template | Conditional pass; footer flagged "1-variant mode" | "regenerate three-variant sketches when web-artifacts-builder is reachable" |
| Mermaid MCP | Server-rendered diagrams | Vendored client-side mermaid.js (SHA256-pinned, network-disabled-safe) | Pass unconditionally; vendored renderer is a first-class path | "no debt -- vendored is canonical" |
| Matt Pocock prototype templates | Source for dt-prototype adaptation | N/A -- vendored at adapt time, no runtime dependency | N/A | N/A |

## Drift Log

Append-only. Each entry: date, dependency, what drifted, decision (accepted with rationale / rolled back).

(empty -- populated when drift is detected and reviewed)
