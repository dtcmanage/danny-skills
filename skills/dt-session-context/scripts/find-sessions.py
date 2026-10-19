"""Query the local session-hub digest cache without loading whole digests.

Usage:
  python find-sessions.py [--machine M] [--workstation W] [--tool T] [--days N]
                          [--grep TEXT] [--limit N] [--json]
  python find-sessions.py --left-off PATH [--chars N]

The cache is the read-only mirror the session-context-hub pusher pulls every
minute: SNOWWHITE D:\\ClaudeSessionHub, fleet2 and the Mac ~/session-hub.
Override with SESSION_HUB_CACHE.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


def cache_root() -> Path:
    override = os.environ.get("SESSION_HUB_CACHE")
    if override:
        return Path(override)
    for candidate in (Path(r"D:\ClaudeSessionHub"), Path.home() / "session-hub"):
        if (candidate / "index.json").is_file():
            return candidate
    raise SystemExit("SESSION_HUB_CACHE_MISSING: no index.json in D:\\ClaudeSessionHub or ~/session-hub")


def load_index(root: Path) -> list[dict]:
    rows = json.loads((root / "index.json").read_text(encoding="utf-8"))
    return sorted(rows, key=lambda r: r.get("last_activity") or "", reverse=True)


def matches(row: dict, args: argparse.Namespace, root: Path, cutoff: datetime | None) -> bool:
    if args.machine and row.get("machine", "").lower() != args.machine.lower():
        return False
    if args.tool and row.get("tool", "").lower() != args.tool.lower():
        return False
    if args.workstation and args.workstation.lower() not in row.get("workstation", "").lower():
        return False
    if cutoff:
        stamp = row.get("last_activity")
        if not stamp or datetime.fromisoformat(stamp) < cutoff:
            return False
    if args.grep:
        try:
            text = (root / row["path"]).read_text(encoding="utf-8", errors="replace")
        except OSError:
            return False
        if args.grep.lower() not in text.lower():
            return False
    return True


def left_off(path: Path, chars: int) -> str:
    text = path.read_text(encoding="utf-8", errors="replace")
    header, _, rest = text.partition("## Where it left off")
    section = rest.split("\n## ", 1)[0]
    return (header.strip() + "\n\n## Where it left off" + section)[:chars]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--machine")
    parser.add_argument("--workstation")
    parser.add_argument("--tool")
    parser.add_argument("--days", type=float)
    parser.add_argument("--grep")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--left-off", dest="left_off")
    parser.add_argument("--chars", type=int, default=6000)
    args = parser.parse_args()

    root = cache_root()
    if args.left_off:
        target = Path(args.left_off)
        if not target.is_absolute():
            target = root / target
        sys.stdout.write(left_off(target, args.chars) + "\n")
        return 0

    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days) if args.days else None
    found = [r for r in load_index(root) if matches(r, args, root, cutoff)][: args.limit]
    if args.json:
        json.dump(found, sys.stdout, indent=1)
        sys.stdout.write("\n")
        return 0
    print(f"cache: {root}  matches: {len(found)}")
    for r in found:
        print(f"{r.get('end_et') or r.get('start_et')} | {r['machine']} | {r['tool']} | "
              f"{r['workstation']} | msgs {r.get('message_count')} | {r['path']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
