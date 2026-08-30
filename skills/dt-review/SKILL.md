---
name: dt-review
description: "Run an adversarial Claude-vs-Codex architecture/design review on a substantive plan until it converges or reaches an explicit cap decision. Trigger on /dt-review, 'dt-review [plan-path]', or requests to pressure-test a non-trivial design. Do NOT use for small bug fixes, single-file edits, initial planning, or build execution."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(codex:*) Bash(claude:*) Bash(git:*) Bash(pwsh:*) Read Write Edit AskUserQuestion SendMessage"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.9.1
  changelog: "Changelog moved to CHANGELOG.md; newest entries first."
---

# dt-review - Adversarial design convergence

## Shared baseline

Apply `../../references/deterministic-reference-policy.md` and resolve paths per
`../../references/conventions.md`. Skill-local rules below are stricter where stated.

`dt-review` pressure-tests a plan through independent cross-family critique (a Codex reviewer for
Claude-authored drafts, a Claude reviewer for Codex-authored drafts) and evidence-based orchestrator
reconciliation. It reviews logic and named evidence; it never treats an unverified current-system claim
as fact.

Retain only:

- `design\design-final-<slug>.md`

Active scratch lives under `design\_review\` and is deleted only by deterministic finalization:

- `draft-v<N>.md`, optional `review-context.md`
- `prompts\codex-critique-prompt-v<N>.md`
- `review-v<N>.json`, rendered/annotated `review-v<N>.md`, redacted stream log, `round-meta-v<N>.json`
- `verdicts.json`, `dispositions-v<N>.json`, optional `round-authorizations.json`
- optional preparation instructions JSON and `finalization-manifest-v<N+1>.json`

## Trigger boundary

Use for a new system/component, a contract-changing refactor, a security/operability-sensitive external
integration, or another hard-to-reverse design. Do not use for bug fixes, copy edits, throwaway
experiments, `dt-plan`, `dt-prototype`, or `dt-build` execution.

## Models, effort, and caps

**Cross-family rule.** The adversarial value of the review comes from a critic at the same capability
and effort as the draft's author, from the *other* model family. At Round 0, record which family
primarily authored the draft (Claude session -> `claude`; Codex session -> `codex`) and route the whole
review through the opposite lane. The lane is fixed for the life of the review, like the tier. Default
lane when authorship is mixed or unclear: `codex` (the Claude orchestrator authored or reconciled it).

Use explicit pins; never inherit `~/.codex/config.toml` (currently Sol/ultra). Explicit pinning is
about provenance, not economy — the complex tier deliberately runs at high effort to match a top-tier
authoring model:

| Role | Codex lane | Claude lane | Limit |
| --- | --- | --- | --- |
| Light review | `gpt-5.6-terra`, effort `medium` | `sonnet` | 3 rounds |
| Complex review | `gpt-5.6-sol`, effort `high` | `opus` | 6 rounds |
| Preflight | `gpt-5.6-luna`, effort `low` | tier model, echo check | 30 seconds |

Any deviation from the tier-default effort (Codex) or model alias (Claude) requires a one-line
recorded reason — the invokers refuse it otherwise (`-EffortReason` / `-ModelReason`) and persist it in
round metadata.

Per-round process timeouts: light rounds keep the enforced 300,000 ms budget; complex rounds run high
effort and get 600,000 ms (10 minutes), matching dt-build's substantive-call budget. The Codex scripts
also use `--ephemeral`, a hermetic temporary working directory, ignored user config, read-only sandbox,
explicit ChatGPT auth, explicit model/effort, and structured output. The Claude lane mirrors this with
a hermetic working directory, default permission mode, an embedded output schema, and the same receipt,
validation, and redaction chain.

The shared resolver validates pins against the account catalog. Fallbacks are:

- Complex: Sol -> Terra -> 5.5 -> 5.4.
- Light: Terra -> Luna -> 5.4 -> 5.4-mini -> 5.5 -> Sol.
- Never select `gpt-5.3-codex-spark`.

When the catalog changes, refresh with `codex debug models`, verify official OpenAI model guidance,
probe each proposed pin read-only, then update this table, both script defaults, and
`scripts/resolve-codex-model.ps1` together.

## References

Read only the branch needed:

- `references/input-modes.md` - Mode A/B/C intake, tier inference, evidence map.
- `references/codex-prompt-template.md` - deterministic assembly and structured-output contract.
- `references/termination.md` - caps and exact state transitions.
- `references/recovery.md` - artifact-state resume rules.
- `references/finalization.md` - glossary reconciliation and safe final commit.
- `references/design-shape.md` - final artifact shape.
- `../../references/canonical-dimension-contract.md` - normative review dimensions.
- `../../references/plan-shape.md` - plan input shape.
- `../../references/glossary-contract.md` - A1-A8 terminology rules at finalization.

## Execution rule

Run every script with `pwsh -NoProfile -File`. On Claude surfaces, call through the Bash tool; on
Codex, use the shell command tool. Set the outer tool timeout slightly above the script's own timeout.
Never hand-roll `codex exec` or `claude -p`, assemble prompts in chat, or pass a prompt through argv.

## Procedure

### 1. Round 0

Follow `references/input-modes.md`:

1. Infer project/workstation/tier from the supplied path and scope, and record the draft's author
   family to fix the reviewer lane (cross-family rule above). Do not routinely ask for tier, lane, or a
   model override; ask only at a genuine fork.
2. Validate plan shape and write `design\_review\draft-v1.md`.
3. Load current canonical constraints. For code-backed/current-data claims, inspect the actual source once
   and write `review-context.md` with paths/queries, hashes or timestamps, and build recheck gates.
   **Hard gate:** once `review-context.md` exists, `draft-v1.md` MUST itself contain the
   `## Build-intake revalidation` table (every live-data assumption with its verification query,
   observed value, and check date) — the assembler refuses Round 1 without it, because the finalizer
   cannot repair the omission after convergence.
4. On resume, switch to `references/recovery.md` instead of restarting.

### 2. Capability preflight

Codex lane — run with a 75-second outer timeout. The script has four sequential internal
budgets (10 + 10 + 15 + 30 seconds) plus bounded cleanup:

```powershell
pwsh -NoProfile -File <skill>\scripts\preflight-codex.ps1 `
  -ProjectPath <abs> -Model gpt-5.6-luna -Tier light -ReasoningEffort low -TimeoutMs 30000
```

This verifies CLI features (`--output-schema`, `--ephemeral`, `--ignore-user-config`), auth, model
resolution, and response. Stop on failure.

Claude lane — echo-check the tier model once before its first substantive round:

```powershell
pwsh -NoProfile -File <skill>\scripts\invoke-claude-round.ps1 `
  -ProjectPath <abs> -Tier <light|complex> -Preflight -TimeoutMs 60000
```

### 3. Round N

1. Assemble the prompt deterministically:

   ```powershell
   pwsh -NoProfile -File <skill>\scripts\assemble-review-prompt.ps1 `
     -ProjectPath <abs> -Round <N> -Tier <light|complex>
   ```

2. Invoke the tier model through the review's fixed lane. Set the outer timeout slightly above the
   script budget: light 300,000 ms budget / 320-second outer; complex 600,000 ms budget / 620-second
   outer.

   Codex lane:

   ```powershell
   pwsh -NoProfile -File <skill>\scripts\invoke-codex-round.ps1 `
     -ProjectPath <abs> -Round <N> -PromptPath <abs-prompt> `
     -Model <tier-model> -Tier <light|complex> `
     -ReasoningEffort <medium|high per tier> -TimeoutMs <300000|600000>
   ```

   Claude lane:

   ```powershell
   pwsh -NoProfile -File <skill>\scripts\invoke-claude-round.ps1 `
     -ProjectPath <abs> -Round <N> -PromptPath <abs-prompt> `
     -Tier <light|complex> -TimeoutMs <300000|600000>
   ```

   Invocation reassembles the canonical prompt and binds prompt, draft, state, tier, and any required
   authorization hashes before and after the model call. A stale or noncanonical `PromptPath` cannot run.
   Effort/model deviations from the tier default require `-EffortReason` (Codex) or `-ModelReason`
   (Claude); both land in `round-meta-v<N>.json`.

3. Parse and persist state:

   ```powershell
   pwsh -NoProfile -File <skill>\scripts\parse-verdict.ps1 `
     -FeedbackPath <review-vN.md> -Round <N> -StatePath <verdicts.json> -Tier <light|complex>
   ```

   Every numbered parse requires `round-meta-v<N>.json` and verifies that its round and tier match
   the caller before persisting the receipt's tier. Keep that tier for every later parse, assembly,
   invocation, termination check, authorization, and finalization in the review. Identical recovery
   reparses reverify the metadata receipt.

4. If `adjudication_required=true`, pause for Danny's A/B/C decision before reconciliation:
   A accept now; B keep rejection with new rationale; C defer as an open question.
   **Settled decisions are never re-adjudicated.** A re-raise of a finding Danny already adjudicated
   arrives in `settled_re_raises` (not `re_raised_rejections`): auto-dispose it with the same
   disposition as the recorded adjudication and a note citing it — no user round-trip. Only if the
   reviewer presents genuinely new evidence the adjudication did not consider may the orchestrator
   voluntarily elevate it to Danny.
5. Independently assess every finding against canonical constraints, actual evidence, reversibility, and
   economy. There is no accept/reject quota. Do not reflexively assimilate the reviewer recommendation.
6. Write `dispositions-v<N>.json` with exact ID coverage and one of ACCEPT/REJECT/DEFER/COUNTER plus an
   evidence-based note. Include `ambiguity_resolution` when flagged and `user_adjudication` for a re-raised
   rejection. Append the same reasoning under `## Orchestrator Response` in `review-v<N>.md`.
7. Record dispositions:

   ```powershell
   pwsh -NoProfile -File <skill>\scripts\record-dispositions.ps1 `
     -StatePath <verdicts.json> -Round <N> -DispositionsPath <dispositions-vN.json>
   ```

8. Run `evaluate-termination.ps1 -StatePath <verdicts.json> -Round <N> -Tier <tier>` and obey its action.

For `CONTINUE` or `APPLY_POLISH_AND_VERIFY`, write immutable `draft-v<N+1>.md` with reconciled changes.
For `APPLY_POLISH_AND_FINALIZE`, follow `references/finalization.md` and use
`prepare-final-draft.ps1`; never hand-write the unreviewed `draft-v<N+1>.md`.
Never edit a reviewed draft in place.

### 4. Cap decision

On `USER_DECISION`, present exactly: extend one round; stop unfinalized; or explicitly accept residual
risk. Residual-risk finalization requires `prepare-final-draft.ps1 -ApprovedResidualRisk` plus the same
switch on the finalizer. Never silently convert a material last verdict into a final design.

**Subagent contract.** When this skill runs inside a subagent (dt-pipeline's review phase or any
spawned agent), there is no direct channel to Danny: on `USER_DECISION` (and any A/B/C adjudication),
immediately send the full decision package — the options, the unresolved findings, current state, and
a recommendation — via SendMessage to the spawning session, then stay responsive for the relayed
decision. Going idle without having sent the package is a contract violation.

If Danny selects an extension, persist it before assembling the next prompt:

- At a cap `USER_DECISION`, first write the reconciled immutable `draft-v<N+1>.md`.
- After `FINALIZE_CURRENT`, the authorizer creates/verifies a byte-identical N+1 confirmation copy.
- After `APPLY_POLISH_AND_FINALIZE`, run `prepare-final-draft.ps1` first; the authorizer replays its
  manifest before allowing the confirmation review.

```powershell
pwsh -NoProfile -File <skill>\scripts\authorize-next-round.ps1 `
  -ProjectPath <abs> -Round <N+1> -Tier <light|complex> `
  -AuthorizedBy Danny -Reason '<explicit decision>'
```

Use the same command for a user-requested confirmation after `FINALIZE_CURRENT` or
`APPLY_POLISH_AND_FINALIZE`. Ordinary `CONTINUE` and `APPLY_POLISH_AND_VERIFY` transitions remain
automatic. The scripts reject skipped, noncontiguous, stale-authorized, or nonlatest rounds.

### 5. Finalize

Follow `references/finalization.md`: carry the build-intake revalidation table, reconcile CONTEXT/glossary
under A1-A8, then run `scripts/finalize-review.ps1`. Only that script may write the final artifact and
delete scratch. Do not generate HTML; that is `dt-visualize-design` on explicit request.

When called by `dt-pipeline` or a subagent, return the final paths to the caller without asking whether to
implement. Otherwise hand off the final path and stop.
