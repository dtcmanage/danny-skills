# Glossary Contract (Normative Terminology Contract)

This is the danny-skills pipeline's **self-contained, executable** terminology contract — the single canonical home for the terminology-placement rules (A1-A8 below). It originated as a normative subset of the glossary-workflow contracts that shipped inline in `dt-design-build` / `dt-design-loop` / `dt-parallel-build` at commit `4d45d2c` (v0.2.3); the commit reference is retained for historical provenance. **This file is the runtime authority:** `dt-session-audit` and the pipeline skills execute the rules below verbatim; changing them is a deliberate edit here plus a version bump, never an edit to a consumer's local copy.

**A1 — Location contract.** A project-scoped term lives in `CONTEXT.md` at the project folder root. A workstation-scoped term lives in `glossary.md` at `<workstation>\<Workstation> Resources\glossary.md`. There is no root-level terminology store.

**A2 — Placement decision.** For each pinned term:

- means the same thing across one whole workstation domain -> workstation `glossary.md`;
- specific to a single project -> that project's `CONTEXT.md`;
- valid in multiple *specific named* workstations, scopes unambiguous -> MULTI_SCOPE: propose parallel `glossary.md` entries (atomic-apply contract);
- a workspace-level canonical (one meaning everywhere) -> "Your call," never auto-filed (root-tier terminology rule, Step 4);
- one word, two genuinely different meanings -> split (A4).

**A3 — Narrowing.** A project `CONTEXT.md` may narrow a workstation term with a delta entry headed "Project-specific narrowing of workstation term `<Term>`", stating only the delta. The workstation baseline definition is not duplicated. Narrowing is additive specialization, not a contradiction.

**A4 — Split-term rule.** When one label carries two genuine meanings, write `<Term> (<qualifier>)` entries for each sense, plus a cross-reference entry under the retired ambiguous label pointing to both.

**A5 — Conflict handling.** A wording-only edit (terminology refine test, Step 3: scope / exclusions / actor-entity mapping / example semantic class all preserved) is classified `auto-handled` and applied on batch approval (no adjudication needed; still subject to Step 6 approval). A meaning-changing conflict pauses with a structured three-option `AskUserQuestion`: (A) Keep, (B) Replace, (C) Split.

**A6 — Promotion gate (project -> workstation).** A `CONTEXT.md` term is a promotion candidate only if all three hold: it appears in 2+ durable artifacts; its definition is implementation-agnostic; no project-specific qualifier is required. Promotion is surfaced, not automatic.

**A7 — Entry format.**

```markdown
## <Term>
**Definition:** <one-sentence canonical meaning>
**Not to be confused with:** <sibling terms and how they differ>
**Example:** <generic or anonymized instance — never a real LP name, account
number, or counterparty identity>
```

**A8 — Redaction.** The `Example` field and any persisted term text obey the redaction fallback ladder (raw secret / masked surrogate / non-secret locator / DROP). No real LP name, account number, or counterparty identity in any glossary or `CONTEXT.md` entry.

