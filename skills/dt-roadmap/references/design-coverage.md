# Design coverage (FS-122)

Read this before producing or splitting a build input. Run `roadmap-validator.ps1` before dt-build
setup; missing ownership fails `COVERAGE_UNMAPPED` and prints each ID and requirement text.

## Requirement unit

Use the full unsplit design as the inventory, never just the repo slice. Each numbered or bulleted
list line (including nested items) under an H2 whose title contains Requirements, Behavior/Behaviour,
Integration, Implementation, Build or Functional is one unit. Implementation/Build/Milestone
Sequence/Order items are included; Build-intake revalidation is excluded. Nested headings inherit
the H2. Ignore fenced examples. Legacy Phase, Contract Freeze Gate and Value Review H3 headings are
also units. IDs are source line numbers (`L120`); the table copies the exact list-line text after its
marker, encoding a literal pipe as `&#124;`. Wrapped prose belongs to the preceding unit; inspect it
when assigning ownership. Source edits that move lines or change list-line text require regeneration.

Put load-bearing prose, tables or differently named sections into an explicit Requirements list
before finalization. Check this normalization against the whole design before splitting; the script
cannot infer requirements from prose. No units is `COVERAGE_EMPTY`, never an empty pass.

The producer auto-maps only top-level sequence items (or legacy phase headings) in a single unsplit
design to their derived M01/M02 milestones. Other units start with milestone `-`, deliberately failing
until the author supplies ownership. It never infers ownership from wording or repository boundaries.
Use the producer's primary-section priority; derive legacy phase milestones only when the selected
sequence yields no milestones. Phase headings alongside a numbered sequence remain requirement units
but gain no automatic ownership and cannot invent remote milestone IDs.

## Tables and split builds

Author `## Design Coverage` in the input, using these exact columns:

| requirement-id | requirement | build-id | milestone-id | owner | reason |
| --- | --- | --- | --- | --- | --- |
| L118 | Add prospect form. | website | M01 | - | - |
| L119 | Add enrichment client. | database | M01 | - | - |
| L120 | Add Outlook draft `-Prospect` mode. | out-of-build | - | Email HQ session | Scripts live outside both repos; complete before switch-on. |

An out-of-build row requires an explicit owner (manual step, other repo or workstation) and reason;
it is pending work, never a waiver. Every requirement has exactly one row. Duplicate IDs, stale text,
unknown IDs/builds/milestones, omitted items and missing source files fail closed.

Each split input has frontmatter `coverage_design: design-final-<slug>.md` (full unsplit source) and
`coverage_build: website` (its own build ID). Each input carries the **same** Design Coverage table
and `## Coverage Builds` registry:

| build-id | input-path |
| --- | --- |
| website | build-input-website.md |
| database | build-input-database.md |

Registry paths are relative to the input, not cwd. The producer resolves them to absolute paths in
the roadmap. Files named `build-input*.md` cannot default to themselves as the full design; missing
parent metadata fails `COVERAGE_SOURCE_MISSING`. Carry the relevant External API Contracts rows and all
sample citations into each affected input, as required by dt-build's `references/fidelity-gates.md`.
The validator opens every registered input, compares shared tables/source/registry and
checks each remote milestone against that input's deterministic sequence/phase IDs. Keep split inputs
together; finish all inputs before validating any roadmap. If a curated remote milestone layout
differs, revise its implementation sequence before generation. A single build defaults to ID `main`
and a one-row registry. A standalone roadmap must also name its design in `coverage_design` (or legacy
`source_artifact`); no source is `COVERAGE_SOURCE_MISSING`. There is no coverage bypass for old roadmaps.

## Close-out and go-live

dt-build's final Markdown and HTML ledgers render every out-of-build row as an unchecked checklist,
including its owner and reason. Carry this checklist into the go-live handoff. The owning human or
session records completion evidence before switch-on; milestone PASS alone does not finish it.
