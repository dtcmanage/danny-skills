# Input Modes (Round 0)

`dt-review` supports three draft-v1 inputs:

## Mode A — Plan file path provided

1. Read the provided markdown file end-to-end.
2. Infer project/workstation from path only as an optimization.
3. Validate inference:
- Workstation must match a Routing Map row.
- Project name cannot be a utility/tooling folder (`skills`, `plugins`, `prompts`, `commands`, `cache`) and
  cannot traverse `00_Resources` or `.claude` between workspace root and plan.
4. Copy plan verbatim into `design/draft-v1.md`.
5. Ensure exactly one `## Dialogue Log` section exists at file end; append only if missing.

If inference validation fails, still use the supplied plan file content, but ask project/workstation
explicitly (same as Mode B/C intake).

## Mode B — Substantive brief in trigger prompt

1. Treat the user's prompt body as the draft plan.
2. Write it verbatim to `design/draft-v1.md`.
3. Ensure exactly one `## Dialogue Log` section exists; append only if missing.

## Mode C — Interactive drafting

Use only when neither Mode A nor B applies:
1. Gather objectives, scope, architecture choices, constraints, open questions.
2. Write resulting draft to `design/draft-v1.md`.
3. Ensure `## Dialogue Log` exists.

## Intake fields

Use one combined `AskUserQuestion` call.

When Mode A inference validation passes, ask only:
- tier (`light`/`complex`)
- optional model override

Otherwise ask all:
- project name
- workstation
- tier
- optional model override
