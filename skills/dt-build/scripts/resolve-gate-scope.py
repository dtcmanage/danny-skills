"""Verify final-integration gate evidence; app gates retain suite selection.

Contract: <danny-skills>/skills/dt-build/references/gate-scope.md.
Read-only: never execute a gate, modify the index, or authorize a skipped gate.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess


def git(repo: Path, *args: str) -> bytes:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True
    ).stdout


def paths(raw: bytes) -> list[str]:
    return [p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p]


def contract_paths(values: list[str]) -> list[str]:
    """Literal repo-relative files/directories, including the ship contract."""
    if not isinstance(values, list) or not values:
        raise ValueError("Declare the gate implementation and suite-map paths")
    for value in values:
        if (not isinstance(value, str) or not value or "\\" in value
                or PurePosixPath(value).is_absolute() or ":" in value
                or any(p in ("", ".", "..") for p in value.split("/"))):
            raise ValueError("Contract paths must be literal repo-relative paths")
    return sorted(set([".ship.json", *values]))


def check_command(repo: Path, command: str, scope: str) -> None:
    if not command.strip() or not scope.strip():
        raise ValueError("Exact gate command and scope are required")
    ship = repo / ".ship.json"
    if ship.exists():
        config = json.loads(ship.read_text(encoding="utf-8"))
        if config.get("gateCommand") and config["gateCommand"] != command:
            raise ValueError("Gate command differs from current .ship.json")


def snapshot(repo: Path) -> dict:
    return {"sha": git(repo, "rev-parse", "HEAD").decode().strip(),
            "tree_hash": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
            "status": git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all").decode(
                "utf-8", "surrogateescape")}


def dependency_snapshot(repo: Path, sha: str, contracts: list[str]) -> dict[str, str]:
    """Hash committed entries, including modes and names, for each literal path."""
    entries = git(repo, "ls-tree", "-r", "-z", sha).split(b"\0")
    result = {}
    for contract in contracts:
        selected = []
        for entry in entries:
            if not entry:
                continue
            name = entry.split(b"\t", 1)[1].decode("utf-8", "surrogateescape")
            if name == contract or name.startswith(contract + "/"):
                selected.append(entry + b"\0")
        result[contract] = hashlib.sha256(b"".join(selected)).hexdigest()
    return result


def resolve_scope(
    repo: Path, command: str, scope: str, contracts: list[str],
    record_paths: list[Path] | None = None,
) -> dict:
    """Return a compatible ancestor and the delta including working changes.

    Missing/invalid evidence falls back to full testing. Git/config errors raise;
    callers must not interpret errors as an empty change set.
    """
    repo = Path(git(repo, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    head = git(repo, "rev-parse", "HEAD").decode().strip()
    contracts = contract_paths(contracts)
    check_command(repo, command, scope)
    records = set(record_paths or [])
    records.update((repo / ".dt-build").glob("**/final-integration.json"))
    accepted: list[tuple[int, str, str]] = []
    rejected: list[dict] = []
    failed_shas: set[str] = set()
    for path in sorted(records, key=str):
        path = path.resolve()
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
            gate = record["gate"]
            sha = gate["sha"]
            if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", sha):
                raise ValueError("Gate SHA must be an immutable full commit hash")
            if gate["command"] != command or gate["scope"] != scope:
                raise ValueError("Gate command or scope differs")
            if contract_paths(gate["contract_paths"]) != contracts:
                raise ValueError("Gate contract paths differ")
            # A conflicting failure for this identity may never be hidden by a PASS.
            if (gate.get("result") != "PASS" or type(gate.get("exit_code")) is not int
                    or gate["exit_code"] != 0 or record.get("result", "PASS") != "PASS"):
                failed_shas.add(sha)
                raise ValueError("Gate or integration did not pass")
            if gate.get("clean") is not True:
                raise ValueError("Gate did not attest a clean committed checkout")
            tree = git(repo, "rev-parse", f"{sha}^{{tree}}").decode().strip()
            if tree != gate["tree_hash"]:
                raise ValueError("Gate tree differs from committed tree")
            expected = {"sha": sha, "tree_hash": tree, "status": ""}
            if gate.get("before") != expected or gate.get("after") != expected:
                raise ValueError("Gate before/after snapshots are missing or changed")
            if gate.get("contract_snapshot") != dependency_snapshot(repo, sha, contracts):
                raise ValueError("Gate dependency snapshot differs")
            git(repo, "merge-base", "--is-ancestor", sha, head)
            # Compare against the working snapshot, so staged/unstaged config
            # changes invalidate reuse too. GIT_LITERAL_PATHSPECS prevents magic.
            literal = [f":(literal){p}" for p in contracts]
            if git(repo, "diff", "--name-only", "-z", sha, "--", *literal):
                raise ValueError("Gate configuration changed")
            untracked = paths(git(repo, "ls-files", "--others", "--exclude-standard", "-z"))
            if any(p == c or p.startswith(c + "/") for p in untracked for c in contracts):
                raise ValueError("Gate configuration has untracked files")
            distance = int(git(repo, "rev-list", "--count", f"{sha}..{head}"))
            accepted.append((distance, sha, str(path)))
        except (ValueError, TypeError, KeyError, OSError, subprocess.CalledProcessError) as exc:
            rejected.append({"record_path": str(path), "reason": str(exc)})
    accepted = [row for row in accepted if row[1] not in failed_shas]
    best = min(accepted) if accepted else None
    if best:
        changed = paths(git(repo, "diff", "--name-only", "--no-renames", "-z", best[1], "--"))
    else:
        # No live-release fallback: without valid evidence every suite is required.
        changed = paths(git(repo, "ls-files", "--cached", "-z"))
    changed += paths(git(repo, "ls-files", "--others", "--exclude-standard", "-z"))
    already_gated = bool(best and best[1] == head and not changed)
    unignored_evidence = any(p.startswith(".dt-build/") for p in changed)
    if git(repo, "rev-parse", "HEAD").decode().strip() != head:
        raise ValueError("HEAD moved during gate scope resolution")
    return {
        "candidate_sha": head,
        "gate_scope_base": {"sha": best[1] if best else None,
                            "record_path": best[2] if best else None,
                            "reason": ("current-head-evidence-requires-validation" if already_gated
                                       else "nearest-valid-gate" if best else "no-valid-gate-full-testing")},
        "already_gated": already_gated,
        "full_test": best is None or already_gated or unignored_evidence,
        "changed_paths": sorted(set(changed)),
        "rejected_records": rejected,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--working-tree", type=Path, required=True)
    parser.add_argument("--command", required=True)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--contract-path", action="append", required=True)
    parser.add_argument("--record", type=Path, action="append", default=[])
    args = parser.parse_args()
    try:
        result = resolve_scope(args.working_tree, args.command, args.scope, args.contract_path, args.record)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"GATE_SCOPE_ERROR: {exc}\n")
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
