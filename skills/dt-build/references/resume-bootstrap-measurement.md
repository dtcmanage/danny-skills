# Managed resume bootstrap measurement (October 11, 2026)

Read-only audit of core-durability-20260922. No live run file was changed. All times below are US Eastern.

The 10:54 PM October 10 coordinator marked **92,544 actual input tokens**. The 1:02 AM October 11 coordinator marked **109,770**. These are actual model counts from successful mark-bootstrap outputs. The table attributes executed command output text with the reproducible o200k_base tokenizer; it is a proxy, not a reconciliation of runtime/tool framing or internal model tokenization.

| Read/output source | 10:54 PM text tokens | 1:02 AM text tokens |
| :-- | --: | --: |
| MEMORY.md | 16,432 | 10,831 |
| CLAUDE.md | 11,210 | 7,512 |
| OneDrive Migration/CLAUDE.md | 2,118 | 1,449 |
| OneDrive Migration/File Sorter/CLAUDE.md | 2,874 | 1,953 |
| 00_Resources/build-process.md | 1,137 | 2,274 |
| installed/dt-build/SKILL.md | 7,951 | 15,902 |
| OneDrive Migration/File Sorter/MEMORY.md | 4,265 | 0 |
| OneDrive Migration/File Sorter/db-durability-refresh/CONTEXT.md | 796 | 0 |
| Other commands, evidence, run records, reconcile/status and discovery | 420 | 10,065 |
| installed/dt-build/references/adapter-codex.md | 1,775 | 1,775 |
| installed/references/conventions.md | 72 | 0 |
| installed/references/deterministic-reference-policy.md | 75 | 0 |
| OneDrive Migration/File Sorter/db-durability-refresh/design/_build-state.md | 4,180 | 2,048 |
| Skill Creation/danny-skills/references/deterministic-reference-policy.md | 407 | 407 |
| Skill Creation/danny-skills/references/conventions.md | 1,607 | 1,607 |
| 00_Resources/model-routing.md | 2,800 | 2,909 |
| 00_Resources/git-workflow.md | 4,191 | 8,382 |
| 00_Resources/ops-conventions.md | 1,786 | 1,998 |
| 00_Resources/codex-cli-usage.md | 8,106 | 0 |
| Skill Creation/danny-skills/skills/dt-build/scripts/dt-job.ps1 | 1,296 | 2,487 |
| File Sorter/MEMORY.md + project CONTEXT.md | 0 | 4,608 |
| Skill Creation/danny-skills/references/html-artifact-policy.md | 0 | 607 |
| Tech-stack (125 lines) + acceptance + codex-cli-usage | 0 | 10,159 |
| installed/dt-build/references/acceptance-contract.md | 0 | 3,042 |
| 00_Resources/workspace-sync.md | 0 | 2,629 |

Rows with combined shell reads include all output from that command. In particular, the 1:02 AM combined tech-stack row includes its first 125 lines, acceptance-contract and codex-cli-usage. The scoped memory row includes CONTEXT.md. Repeated reads are counted each time; root CLAUDE.md was native and is included in runtime context rather than command output.

Before bootstrap, the first coordinator read required parent files **three times**, and codex-cli-usage **twice**. The second read parent files twice, the entire dt-build skill twice, build-process twice, git-workflow twice, plus acceptance, routing, sync, checkpoint, evidence and discovery. A failed evidence read delayed the successful marker. Additional tech-stack and session-audit skill reads after the marker then exhausted the hard margin without a job dispatch.

## Individual current file contributions

These are October 11 source-text measurements, excluding tool framing. This inventory includes the files that combined historical shell reads cannot split exactly.

| File | o200k_base tokens | Resume timing |
| :-- | --: | :-- |
| CLAUDE.md | 6,054 | native; do not reread |
| MEMORY.md | 5,340 | required |
| _Claude-Workspace/CLAUDE.md | 3,696 | required |
| _Claude-Workspace/OneDrive Migration/CLAUDE.md | 668 | required |
| _Claude-Workspace/OneDrive Migration/File Sorter/CLAUDE.md | 920 | required |
| _Claude-Workspace/OneDrive Migration/File Sorter/MEMORY.md | 4,209 | scoped current state |
| _Claude-Workspace/OneDrive Migration/File Sorter/db-durability-refresh/CONTEXT.md | 398 | scoped terminology |
| _Claude-Workspace/TCM Tech Stack Reference.md | 43,285 | when implementation step is triggered |
| _Claude-Workspace/00_Resources/git-workflow.md | 4,190 | before git action |
| _Claude-Workspace/00_Resources/model-routing.md | 2,900 | before dispatch |
| _Claude-Workspace/00_Resources/build-process.md | 1,136 | before marker |
| _Claude-Workspace/00_Resources/ops-conventions.md | 1,993 | when launcher/alert step is triggered |
| _Claude-Workspace/00_Resources/codex-cli-usage.md | 4,052 | before invoking/configuring Codex |
| _Claude-Workspace/00_Resources/workspace-sync.md | 2,621 | at actual sync step |
| skills/dt-build/references/acceptance-contract.md | 3,041 | before acceptance gate |
| skills/dt-build/SKILL.md | 8,161 | current execution sections after marker |
| skills/dt-session-audit/SKILL.md | 3,840 | at actual close-out |
| run/build-state.md | 288 | before marker |
| run/build-plan.md | 265 | before marker |
| run/approvals.json | 59 | before marker |
| run/reference-manifest.md | 321 | when current milestone needs frozen contract data; never also reread source |
| run/reference-pack-contracts.md | 2,271 | when current milestone needs frozen contract data; never also reread source |
| run/reference-pack-glossary.md | 790 | when current milestone needs frozen contract data; never also reread source |
| _build-state.md (current live file, read only) | 2,096 | before marker; lean writer bounds future rewrites at 8 KiB |

## Budget and regression gate

The representative Codex-pinned resume budget is **45,339 text tokens**, including an 18,000-token reserve for native/runtime/tool context and 6,000 for checkpoint, run records, complete approvals and operative boundary sources. The native/runtime reserve is calibrated from the first 1:02 AM input (28,397) minus its initial required-read output proxy (11,097): 17,300, rounded up. The safety reserve cannot be satisfied by omitting an authorization read. The new guide explicitly requires all original boundary sources before marking.

The versioned read-plan fixture retains source counts/hashes. Regression tests remeasure current repo files and, on this workstation, current canonical files. At 50,000 or above the budget check fails. A separate observed-transcript check uses the actual successful marker value and rejects 50,000 or above, including the historical 109,770 case. Install scripts/requirements-bootstrap.txt for the pinned tokenizer.

**Limitation:** 45,339 is a measured read-plan budget, not proof of a newly launched coordinator baseline. No new coordinator was launched against the live run. Runtime overhead, oversized existing boundary documents or a model disregarding the entry contract can raise actual context. The observed-transcript check must be run on the next actual resume before claiming its baseline is below 50,000.

Example diagnostic: `python scripts/measure-resume-bootstrap.py --transcript <rollout.jsonl>`; exit 1 means the actual baseline exceeded the target. Add `--diagnostic` only for historical reporting. The watcher still counts a rotation with no new job events as thrash, regardless of its marker size.

## Historical ledger replay

A read-only replay of the original launch/event rows recognizes all five continuations after the first launch as productive predecessors. The 11:08 PM successor was triggered by a detached job completion just after the 11:07 PM rotation request; progress credit must follow the predecessor's continuation, even when the launch trigger is a newer terminal event. The regression proof covers this ordering. The three coordinators starting at 12:58 AM, 1:02 AM and 1:06 AM recorded no new job events before their rotations and remain thrash. The new cap pauses after six counted launches, rather than after six total launches.

Legacy continuation rows without requested_by/consumed_event_seq use episode timestamps and the run's current consumed cursor. New continuation rows snapshot the cursor under the run lock and name the requester, so later consumption cannot turn an unconsumed-trigger episode into a productive one. A legacy ledger cannot retroactively prove the exact cursor at continuation time; this compatibility fallback is explicit.

Token counts normalize CRLF to LF consistently. The earlier 45,360 budget fell by 21 tokens after normalization: root MEMORY.md contributed 19 fewer and workspace CLAUDE.md 2 fewer; no canonical file content was changed by this fix.
