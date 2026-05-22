# Logic Prototype

Use this branch when the question is about behavior: state transitions, reducer design, classification rules,
or policy logic that needs button-press validation instead of prose argument.

## Success target

- The prototype runs with one command in the host project.
- Danny can trigger actions and immediately see full state after each action.
- `NOTES.md` captures what the run proved and what should change in the real design/code.

## Steps

1. State the question first
- Write one paragraph at the top of `NOTES.md` describing:
  - the exact behavior question,
  - what "wrong" would look like.

2. Pick runtime by host stack
- If the host is TypeScript/Node-first, start from `assets/logic-prototype.ts.template`.
- If the host is Python-first, start from `assets/logic-prototype.py.template`.
- If unclear, ask once; do not invent a runtime.

3. Keep logic portable
- Put the core logic behind a pure surface (reducer/state-machine/functions).
- The terminal shell can be throwaway; the logic module should be liftable.
- No terminal I/O inside the core logic.

4. Build the smallest interactive TUI
- Render one screen per tick (clear + redraw).
- Show:
  - current state (full, readable),
  - key bindings (single-key actions),
  - quit action.
- Re-render after every action.

5. One command to run
- Add to host runner (`package.json`, `make`, `just`, etc.) when possible.
- Otherwise place exact run command at top of `NOTES.md`.

6. Capture answer and cleanup intent
- In `NOTES.md`, include:
  - observed edge cases,
  - accepted behavior,
  - what should be changed in plan/code,
  - explicit "delete after decision" note.

## Anti-patterns

- Writing tests for the prototype.
- Coupling prototype to production DB/services unless that integration is the question.
- Mixing UI shell concerns into the core logic module.
- Leaving no durable decision record (`NOTES.md` missing or empty).

