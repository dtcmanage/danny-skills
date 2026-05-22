## Canonical Dimension Contract

**Framework state:** `provisional`. The acceptance-test runbook has not yet been run, so the six dimensions and their boundaries are the working set — used, but treated as not-yet-final. The set becomes `frozen` only when the runbook passes and Danny declares it. Surface the current state (`provisional` / `frozen`) in this skill's round provenance / plan metadata.

The Canonical Dimension Contract is maintained as a single source at the repo-level `references/canonical-dimension-contract.md`. Pipeline skills reference it from there rather than copying it; any skill that still carries an inline copy keeps that copy byte-identical to the canonical file, and the release checklist diffs each inline copy against it — any mismatch blocks the release.

### The six dimensions

Every finding is filed under **exactly one** dimension. The axis is one question: *the design fails because…*. A finding is never dual-filed.

**Tie-break rule — route by root cause, not symptom.** When a finding seems to fit two dimensions, assign it by root cause. A timeout that crashes the system is *Resilience* if the root cause is missing failure handling; *Feasibility* if the root cause is a latency target that cannot be built; *Economy* if the root cause is an over-engineered path that did not need to exist. The symptom is shared; the root cause is singular.

**`AMBIGUOUS_ROOT_CAUSE` handling.** When the root cause genuinely spans two dimensions and cannot be reduced to one, do not silently route to a default. The reviewer: (1) names the two candidate dimensions; (2) states the specific missing evidence that would disambiguate; (3) assigns a temporary primary for filing, marked provisional; (4) flags the finding `AMBIGUOUS_ROOT_CAUSE`. Even when flagged, the finding is filed under exactly one temporary primary — dual-filing is prohibited; the flag records uncertainty about *which* single dimension is correct, never licence to file twice. The **ambiguity rate** (share of findings flagged `AMBIGUOUS_ROOT_CAUSE`, and the dimension pairs involved) is tracked, not hidden — a pair that repeatedly draws ambiguous findings is evidence its boundary needs sharpening.

**Closure rule.** A temporary primary must not silently become permanent. Every `AMBIGUOUS_ROOT_CAUSE` finding is revisited within the same review cycle once the stated missing evidence is available — the temporary primary is then confirmed or reassigned and the flag cleared. If the evidence cannot be gathered within the cycle, the finding is carried forward with a named owner and a date recorded in the round's provenance — never left silently flagged.

**Intent** — the design solves the wrong problem, or rests on a false / unstated assumption about the problem.
- *Belongs here if:* the finding is about whether the goal itself is right — wrong problem framing, an unvalidated premise, a misread of what the user / stakeholder needs.
- *Does not belong if:* the goal is right but something under it is missing (→ Completeness) or contradictory (→ Coherence).
- *Examples:* building a caching layer when the real problem is an unindexed query; assuming users want speed when they want auditability; a strategy plan that optimizes a metric the business does not care about.

**Completeness** — the problem is framed right, but the design misses required cases, scope, or inputs.
- *Belongs here if:* something needed is absent — an unhandled case, an unscoped requirement, a missing input or actor.
- *Does not belong if:* the missing thing is a failure / attack path (→ Resilience); present but contradictory (→ Coherence); present but disproportionate (→ Economy).
- *Examples:* a form flow with no "edit existing record" path; a migration plan that omits rollback; a hiring plan that never addresses onboarding.

**Coherence** — the design contradicts itself, or a contract / interface between its parts is under-specified.
- *Belongs here if:* two parts disagree, a term is used two ways, or a hand-off contract (section order, marker names, data shape) is ambiguous.
- *Does not belong if:* the parts agree but a needed part is absent (→ Completeness).
- *Examples:* Step 3 outputs a field Step 5 never consumes; "out of scope: implementation" while also requiring implementation detail; a process doc where two roles both own the same approval.

**Resilience** — the design breaks under failure, load, or adversarial conditions.
- *Belongs here if:* the finding is about behavior under stress — failure modes, degraded operation, load ceilings, attack / abuse paths, untrusted input.
- *Does not belong if:* the system simply cannot be operated at all (→ Feasibility); a required normal-path case is missing (→ Completeness).
- *Examples:* no retry / backoff on a flaky upstream; an admin endpoint with no authz check; a plan that pastes untrusted artifact text into a prompt with no instruction-injection guard.

**Resilience — security minimum checks.** The Resilience review must address each item, or mark it N/A to the standard below:
- *Identity* — who is acting, and is it verified.
- *Authorization* — is the actor allowed to do this.
- *Secrets handling* — credentials, keys, tokens not exposed or logged.
- *Data boundaries / exposure* — sensitive data not leaked into outputs, artifacts, or logs.
- *Abuse / injection* — for designs that consume external text, does the design treat external input as data, not instructions (the prompt-injection surface).
- *Dependency / supply chain* — for each applicable dependency risk, name one concrete control (a version-pinning policy, a stated trust source, a named vuln-monitoring owner). A design with no external dependencies states "no external dependencies" and that satisfies the item.

**Minimum N/A standard.** "Not applicable" is valid only if it states all three of: (a) the threat actor considered, (b) the relevant data flow, (c) why the check is genuinely out of scope for this artifact. An N/A missing any of the three leaves the Resilience review incomplete.

**Economy** — the design is over- or under-built relative to the value it must deliver, measured as value-density against the stated objective and constraints.
- *Belongs here if:* something present is disproportionate to its value (over-built), or a present thing is too thin to deliver its stated value (mis-proportioned). Evidence-style checks: complexity budget, maintenance burden, time-to-value.
- *Does not belong if:* a required thing is entirely absent (→ Completeness); the thing cannot be operated at all (→ Feasibility). Economy is about proportion, not presence.
- *Examples:* a bespoke queue where a cron job suffices; a five-stage approval chain for a low-risk change; a microservice split that triples ops burden for no scaling need.

**Feasibility** — the design cannot realistically be built, operated, or maintained with the available means.
- *Belongs here if:* the blocker is capability / resource / operability — an unbuildable target, a skill or budget gap, an unmaintainable ongoing burden.
- *Does not belong if:* the thing is buildable but fragile under stress (→ Resilience) or merely disproportionate (→ Economy).
- *Examples:* a latency target below physical network limits; a plan needing a team skill no one has; an ops model requiring 24/7 staffing the org cannot fund.

### Per-finding output contract

Every finding produced under any dimension carries:
- **Dimension** — the single dimension it is filed under.
- **`AMBIGUOUS_ROOT_CAUSE` flag** — present only when the tie-break could not reduce the finding to one root cause; records the two candidate dimensions and the missing evidence (see the tie-break rule).
- **Severity** — high / medium / low, per the Severity rubric below.
- **Concrete remediation** — a specific proposed fix, not just a gap statement.
- **Validation check** — the observable test that confirms the remediation worked.
- **Owner role** — conditionally required: optional by default; **required when the finding is `Severity = High` AND the artifact is multi-actor**. Omitted otherwise.

**Severity rubric.** Severity in design review is driven by impact and reversibility — a hard-to-reverse architectural commitment outranks an equally impactful but easily-changed choice.
- **High** — large impact on the design's success AND hard to reverse once built.
- **Medium** — significant impact OR hard to reverse, but not both.
- **Low** — limited impact and easily reversible.

### Domain overlays

The six dimensions are fixed and domain-neutral. Domain versatility comes from **overlays** — per-domain question banks (dev / business / process) layered on the fixed six. A business-strategy overlay surfaces stakeholder-alignment and adoption-risk questions under Intent and Feasibility; a process overlay surfaces governance and hand-off questions under Coherence and Resilience. The top-level set never changes per domain — only the prompting questions beneath it do.

**Overlay contract.** Every overlay question must: (1) map to exactly one of the six core dimensions; (2) carry a one-line rationale stating why it belongs under that dimension; (3) pass the same pairwise-overlap check before release. An overlay question that cannot be cleanly mapped is escalated — it is evidence the question is malformed or the core set has a real gap. It is never silently absorbed.
