"""Measure a resume read plan, or attribute an observed Codex bootstrap transcript.

o200k_base is a reproducible text-token proxy; transcript input_tokens is the actual
model measurement. Install the pinned dependency in requirements-bootstrap.txt.
No run files are modified. The budget includes runtime overhead and safety reads.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import tiktoken


def measure_plan(manifest_path: Path, repo_root: Path, canonical_root: Path | None = None) -> dict[str, object]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    encoder = tiktoken.get_encoding("o200k_base")
    components = list(manifest["measured_components"])
    if canonical_root:
        for component in components:
            if "sha256" in component:
                source = canonical_root / component["source"]
                component["tokens"] = len(encoder.encode(source.read_text(encoding="utf-8")))
                component["measurement"] = "current canonical file, o200k_base"
    for relative in manifest["repo_reads"]:
        source = repo_root / relative
        tokens = len(encoder.encode(source.read_text(encoding="utf-8")))
        components.append({"source": relative, "tokens": tokens, "measurement": "current file, o200k_base"})
    total = sum(item["tokens"] for item in components)
    return {"components": components, "total_tokens": total, "target_tokens": manifest["target_tokens"],
            "pass": total < manifest["target_tokens"], "kind": "resume read-plan budget; not a live model baseline"}


def measure_transcript(transcript_path: Path) -> dict[str, object]:
    encoder = tiktoken.get_encoding("o200k_base")
    commands: list[dict[str, object]] = []
    actual: int | None = None
    # Use executed commands, not prompts/skill text that merely mention mark-bootstrap.
    for line in transcript_path.read_text(encoding="utf-8").splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        payload = row.get("payload", {})
        if row.get("type") == "event_msg" and payload.get("type") == "token_count":
            actual = payload.get("info", {}).get("last_token_usage", {}).get("input_tokens", actual)
        item = payload.get("item", {})
        if payload.get("type") != "item_completed" or item.get("type") != "CommandExecution":
            continue
        command = item.get("command", [""])[-1]
        output = item.get("aggregated_output", "")
        marker = re.search(r'"baseline_tokens"\s*:\s*(\d+)', output)
        if marker and ("-Verb mark-bootstrap" in command or "dt-job.ps1' mark-bootstrap" in command):
            actual = int(marker.group(1))
            break
        commands.append({"command": command, "text_tokens": len(encoder.encode(output))})
    else:
        raise ValueError("No successful executed mark-bootstrap found in transcript")
    if actual is None:
        raise ValueError("No actual input_tokens measurement before marker")
    return {"commands": commands, "command_output_text_tokens": sum(c["text_tokens"] for c in commands),
            "actual_input_tokens_before_marker": actual,
            "note": "Command outputs use o200k_base; actual input includes runtime, native context, tool formatting, commands and reasoning."}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--transcript", type=Path)
    parser.add_argument("--canonical-root", type=Path)
    parser.add_argument("--max-tokens", type=int, default=50000)
    parser.add_argument("--diagnostic", action="store_true", help="Report historical oversize without a failing exit")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if bool(args.manifest) == bool(args.transcript):
        parser.error("Supply exactly one of --manifest or --transcript")
    result = measure_transcript(args.transcript) if args.transcript else measure_plan(args.manifest, args.repo_root, args.canonical_root)
    if args.transcript:
        result["target_tokens"] = args.max_tokens
        result["pass"] = result["actual_input_tokens_before_marker"] < args.max_tokens
    rendered = json.dumps(result, indent=2, ensure_ascii=True)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0 if args.diagnostic or result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
