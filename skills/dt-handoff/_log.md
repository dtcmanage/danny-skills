Append-only friction notes. One line per invocation that hit friction.

## 2026-11-24 — stale-handoff adjudication should not go to Danny (route via dt-tune)

Danny (2026-11-23), on being asked whether a 38-day-old handoff was stale: "if it's already been overlapped since its creation, then it's obviously stale. i dont know that until you read it and tell me. if it is indeed stale then delete it." Step 2 currently hands Danny a table and asks him to judge each OPEN handoff. Proposed amendment: the session reads each OPEN handoff, checks its claims against code/git, decides stale vs pending itself, acts (stale -> consumed), and reports the verdict with evidence; ask only when the evidence is genuinely mixed. Note he said "delete"; the convention moves to consumed/, which keeps it recoverable.
