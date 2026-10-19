"""Measure a resume read plan, or attribute an observed Claude Code or Codex bootstrap transcript.

o200k_base is a reproducible text-token proxy; transcript input_tokens is the actual
model measurement. Install the pinned dependency in requirements-bootstrap.txt.
No run files are modified. The budget includes runtime overhead and safety reads.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
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
    for item in manifest.get("rendered_reads", []):
        output = subprocess.run(item["command"], cwd=repo_root, check=True, capture_output=True, text=True).stdout
        components.append({"source": item["source"], "tokens": len(encoder.encode(output)),
                           "measurement": "current rendered rulebook, o200k_base"})
    total = sum(item["tokens"] for item in components)
    return {"components": components, "total_tokens": total, "target_tokens": manifest["target_tokens"],
            "pass": total < manifest["target_tokens"], "kind": "resume read-plan budget; not a live model baseline"}


def measure_transcript(transcript_path: Path) -> dict[str, object]:
    encoder = tiktoken.get_encoding("o200k_base")
    commands: list[dict[str, object]] = []
    pending: dict[str, str] = {}
    overhead: int | None = None
    first_seen = False
    actual: int | None = None

    def output_text(value: object) -> str:
        if isinstance(value, str):
            return value
        if isinstance(value, list):
            return "\n".join(output_text(item) for item in value)
        if isinstance(value, dict):
            return output_text(value.get("text", value.get("content", "")))
        return ""

    def executed(command: str, output: str, failed: bool = False) -> int | None:
        marker = re.search(r'"baseline_tokens"\s*:\s*(\d+)', output)
        is_mark = bool(re.search(r"(?:-Verb\s+|dt-job\.ps1[\"']?\s+)mark-bootstrap(?:\s|$)", command))
        if is_mark and marker and not failed:
            return int(marker.group(1))
        commands.append({"command": command, "text_tokens": len(encoder.encode(output))})
        return None

    for line in transcript_path.read_text(encoding="utf-8-sig").splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        payload = row.get("payload", {})
        kind = row.get("type")
        if kind == "assistant" and not row.get("isSidechain"):
            message = row.get("message", {})
            if not first_seen:
                first_seen = True
                usage = message.get("usage") or {}
                total = sum(usage.get(key, 0) or 0 for key in
                            ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                overhead = total if total > 0 else None
            for block in message.get("content", []):
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    inputs = block.get("input", {})
                    command = inputs.get("command", inputs.get("cmd", ""))
                    if isinstance(command, str):
                        pending[block["id"]] = command
        elif kind == "user":
            for block in row.get("message", {}).get("content", []):
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    actual = executed(pending.pop(block.get("tool_use_id"), ""),
                                      output_text(block.get("content", "")), bool(block.get("is_error")))
                    if actual is not None:
                        break
        elif kind == "event_msg" and payload.get("type") == "token_count" and not first_seen:
            first_seen = True
            overhead = ((payload.get("info") or {}).get("last_token_usage") or {}).get("input_tokens")
        elif kind == "response_item" and payload.get("type") in ("function_call", "custom_tool_call"):
            arguments = payload.get("arguments", payload.get("input", ""))
            try:
                inputs = json.loads(arguments)
                command = inputs.get("cmd", inputs.get("command", ""))
            except (ValueError, TypeError):
                command = str(arguments)
            pending[payload["call_id"]] = command
        elif kind == "response_item" and payload.get("type") in ("function_call_output", "custom_tool_call_output"):
            actual = executed(pending.pop(payload.get("call_id"), ""), output_text(payload.get("output", "")))
        elif payload.get("type") == "item_completed":
            item = payload.get("item", {})
            if item.get("type") == "CommandExecution":
                command = item.get("command", "")
                if isinstance(command, list):
                    command = " ".join(command)
                actual = executed(command, item.get("aggregated_output", ""), item.get("exit_code", 0) != 0)
        if actual is not None:
            break
    if actual is None:
        raise ValueError("No successful executed mark-bootstrap found in transcript")
    known = overhead is not None and 0 <= overhead <= actual
    return {"commands": commands, "command_output_text_tokens": sum(c["text_tokens"] for c in commands),
            "actual_input_tokens_before_marker": actual, "baseline_tokens": actual,
            "host_overhead_tokens": overhead if known else None,
            "coordinator_added_tokens": actual - overhead if known else actual,
            "bootstrap_measurement": "baseline minus first-turn host overhead" if known else
                                     "host overhead unavailable; using full baseline",
            "note": "Full baseline still controls context-guard limits; command outputs use o200k_base."}


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
        result["pass"] = result["coordinator_added_tokens"] < args.max_tokens
    rendered = json.dumps(result, indent=2, ensure_ascii=True)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0 if args.diagnostic or result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
