Append-only friction notes. One line per invocation that hit friction.
2026-07-10 dt-build: intake-dry-run.ps1 reads $LASTEXITCODE under StrictMode before a native command initializes it; invoking in-process after setting $global:LASTEXITCODE=0 was required.
2026-07-10 dt-build: the state branch dt-build/<RUN_ID> conflicts with required chunk refs below dt-build/<RUN_ID>/... because Git cannot store a ref as both a file and a directory; a non-colliding dt-build-chunk/<run>-<milestone> source ref was required for CAS checkpointing.
