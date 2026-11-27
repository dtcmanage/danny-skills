"""Run an exact PowerShell gate and atomically update its final-integration evidence.

Trusted local execution; see references/gate-scope.md. No shipping or approvals.
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

SPEC = importlib.util.spec_from_file_location("gate_scope", Path(__file__).with_name("resolve-gate-scope.py"))
SCOPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCOPE)
ACTIVE = "DT_BUILD_RECORD_GATE_ACTIVE"


def active_targets(repo: Path, output: Path, log: Path) -> list[dict[str, str]]:
    """Propagate canonical targets; isolated fixture apps may record their gates."""
    try:
        targets = json.loads(os.environ.get(ACTIVE, "[]"))
    except ValueError as exc:
        raise ValueError("Invalid active recorder targets") from exc
    if (not isinstance(targets, list) or any(
            not isinstance(target, dict) or set(target) != {"repo", "record", "log"}
            or any(not isinstance(value, str) or not Path(value).is_absolute()
                   for value in target.values()) for target in targets)):
        raise ValueError("Invalid active recorder targets")
    for target in targets:
        if (Path(target["repo"]).resolve() == repo
                or {Path(target[key]).resolve() for key in ("record", "log")} & {output, log}):
            raise ValueError("Recursive record-gate execution is forbidden for the same app or output")
    return [*targets, {"repo": str(repo), "record": str(output), "log": str(log)}]


def safe_output(repo: Path, path: Path) -> Path:
    """Evidence must be external or ignored, never tracked, linked or Git metadata."""
    path = path.absolute()
    if any(part.is_symlink() for part in [path, *path.parents]):
        raise ValueError("Evidence output must not traverse symlinks")
    path = path.resolve()
    for arg in ("--absolute-git-dir", "--git-common-dir"):
        metadata = Path(SCOPE.git(repo, "rev-parse", arg).decode().strip())
        if path.is_relative_to((repo / metadata).resolve()):
            raise ValueError("Evidence output must not enter Git metadata")
    if path.is_relative_to(repo):
        relative = path.relative_to(repo).as_posix()
        if (relative == ".git" or relative.startswith(".git/")
                or SCOPE.git(repo, "ls-files", "-z", "--", f":(literal){relative}")):
            raise ValueError("Evidence output must not overwrite tracked files")
        ignored = subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", "--", relative])
        if ignored.returncode != 0:
            raise ValueError("In-repo evidence output must be ignored (ignore .dt-build/ first)")
    if path.exists() and not path.is_file():
        raise ValueError("Evidence output must be a regular file")
    return path


def atomic_record(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".gate-", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(record, stream, ensure_ascii=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def run_gate(repo: Path, command: str, scope: str, contracts: list[str],
             output: Path, records: list[Path] | None = None) -> dict:
    repo = Path(SCOPE.git(repo, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    contracts = SCOPE.contract_paths(contracts)
    SCOPE.check_command(repo, command, scope)
    output = safe_output(repo, output)
    log = safe_output(repo, output.with_suffix(".gate.log"))
    targets = active_targets(repo, output, log)
    record = json.loads(output.read_text(encoding="utf-8")) if output.exists() else {}
    if not isinstance(record, dict):
        raise ValueError("Final integration record must be an object")
    before = SCOPE.snapshot(repo)
    if before["status"]:
        raise ValueError("Gate requires a clean committed candidate")
    dependencies = SCOPE.dependency_snapshot(repo, before["sha"], contracts)
    selection = SCOPE.resolve_scope(repo, command, scope, contracts, [*(records or []), output])
    if SCOPE.snapshot(repo) != before:
        raise ValueError("Candidate changed before gate execution")
    gate = dict(sha=before["sha"], tree_hash=before["tree_hash"], command=command,
                scope=scope, contract_paths=contracts, contract_snapshot=dependencies,
                before=before, after=None, clean=False, result="FAIL", exit_code=None,
                log_path=str(log))
    record.update(gate=gate, gate_scope=selection)
    # Invalidate any old PASS before launching, including interruptions/crashes.
    atomic_record(output, record)
    log.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, **{ACTIVE: json.dumps(targets), "DT_BUILD_GATE_SCOPE_JSON": json.dumps(selection)})
    # Match Invoke-ShipStep in dt-ship/scripts/ship.ps1: UTF-16LE EncodedCommand,
    # no profile, no interactive input, and no wrapper that changes exit semantics.
    encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
    try:
        with log.open("w", encoding="utf-8") as stream:
            completed = subprocess.run(
                ["pwsh", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                cwd=repo, env=env, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
        gate["exit_code"] = completed.returncode
    finally:
        gate["after"] = SCOPE.snapshot(repo)
        gate["clean"] = gate["after"] == before
        gate["result"] = "PASS" if gate["clean"] and gate["exit_code"] == 0 else "FAIL"
        # Recheck destinations in case the gate changed ignore rules or links.
        safe_output(repo, output)
        atomic_record(output, record)
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--working-tree", type=Path, required=True)
    parser.add_argument("--command", required=True)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--contract-path", action="append", required=True)
    parser.add_argument("--record", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        record = run_gate(args.working_tree, args.command, args.scope, args.contract_path,
                          args.output, args.record)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"GATE_RECORD_ERROR: {exc}\n")
    print(json.dumps({"record_path": str(args.output), "gate": record["gate"]}))
    if record["gate"]["result"] != "PASS":
        parser.exit(1, "GATE_RECORD_ERROR: gate failed or candidate changed; see saved evidence/log\n")


if __name__ == "__main__":
    main()
