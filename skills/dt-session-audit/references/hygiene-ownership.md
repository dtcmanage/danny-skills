# Hygiene ownership and to-do deduplication

Mandatory before every audit to-do creation, including every Command Center backstop
write (SKILL step 7), and when the bloat detector finds an oversized scaffold before
hygiene dispatch or any out-of-scope handoff.

1. Read the canonical Command Center workstation policy and its current API/tool
   instructions. List **all open items** (`cc.ps1 list` with no `--workstation` filter,
   including waiting, scheduled and running)
   and **live sessions/owners**, including master-child relationships and the current
   session. Fetch full candidate records; a title match alone does not establish
   duplicate coverage. If either inventory fails or is incomplete, do not create a
   replacement item or launch work. Report the coverage gap to the master (or Danny
   in a top-level session) and continue independent authorized audit work.
2. Resolve the canonical workstation and exact scaffold paths. Compare each candidate
   item's scope, next action, assignee/session, status and scheduled run with the live
   owner's declared workstation. Any open session or master that owns that workstation
   suppresses an outside-scope hygiene handoff, regardless of its current task or
   whether it has started scaffold maintenance.
   Folder proximity alone is insufficient to establish that ownership.
   An open hygiene item covers the finding when its named paths/workstation and next
   action already include the required cleanup. Either condition suppresses a new
   hygiene handoff, item or session, even when the other inventory has no match.
3. Within this audit's authorized in-play session scope, reuse the existing item and
   update its evidence/next action only under the canonical session write rule. Keep
   its owner and existing work intact; do not reassign or dispatch a second worker.
   With no existing coverage, act only within the audit's existing authorization.
4. Outside the in-play scope, never edit the scaffold or start hygiene merely because
   the detector found bloat. In a child session, report the exact paths, detector
   counts, covering item IDs/live owner IDs and the suppressed duplicate to the master
   **once**. Check this session's prior reports before sending; append new evidence to
   the same report/item rather than issue a new handoff. Leave the existing owner to
   perform its work. In a top-level session, report the finding once through the
   canonical channel. Do not manufacture a to-do when an active owner already covers it.
5. Immediately before any genuinely new item creation, refresh both inventories and
   repeat the full candidate comparison. Update an existing covering item instead if
   one appeared. Record coverage, the existing item/owner IDs, and the resulting
   action or suppression in the audit result. Any escalation remains bounded by the
   audit's authorization and the master-child policy.

Verification cases: live owner only -> suppress; open covering item only -> suppress;
both -> reuse without new dispatch; unrelated item/owner -> no inferred coverage;
inventory failure -> no creation; repeated child audit -> one master report; authorized
in-play maintenance -> existing audit authority, with the same creation precheck.
