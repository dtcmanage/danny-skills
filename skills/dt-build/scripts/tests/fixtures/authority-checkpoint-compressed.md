# Build State - Sanitized compressed live checkpoint shape
run_status: awaiting_danny
last_consumed_event_seq: 1563
## In flight
- RUN=__RUN__
- WORK=RUN/milestones/M05/current-work
- PARENT=PARENTWORK/successor-3 unchangedFINALseal; WORK/successor-1 ABSENT.
- PARENTWORK=RUN/milestones/M05/parent-work
- SPACED=PARENTWORK/folder with spaces
- STOP=PARENTWORK/local-stop-current. Beforebootstrap read source-disposition.json,next-scope.md,next-operation-boundary.json,next-approval.md IN FULL plus all95 inherited originals through inherited_boundary (99total); verifiedcurrentrunrecord/completeapprovals/operator-notes/lease/checkpoint mandatory. Standingnotes solelyRUN/operator-notes.json.
- Also beforebootstrap read PARENTWORK/coordinator-metadata-disposition.md, coordinator-full-failure-disposition.md, coordinator-notes-locator-disposition.md, coordinator-report-path-metadata-disposition.md IN FULL. These bounded necessarymetadata clarifications grant no newauthority.
- Separatelyreconcile ONLY after localgates via RUN/milestones/M05/base/local-stop-base/{source-disposition.json,next-scope.md,next-operation-boundary.json,next-approval.md}.
- Beforebootstrap also read WORK/vendor-capacity-stop.md IN FULL. WORK/session-audit.md captures bounded stop. No new authorization.
- Historical evidence WORK/absent-evidence.md is ABSENT; no bootstrap read requested.
