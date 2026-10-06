"""Loopback golden review. Callers supply isolated or live state explicitly.

No alerts, browser launches, or implicit approvals. A bank edit resets every choice.
"""
from __future__ import annotations

import argparse
from datetime import date, datetime, timezone
import hashlib
from html import escape
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import secrets
import time
from typing import Any
from urllib.parse import parse_qs


TASKS = Path(__file__).resolve().parent / "tasks"
IGNORED = {"node_modules", "__pycache__", ".pytest_cache"}


def private_bank_path(state: Path) -> Path:
    """Private tasks live beside the router state directory, outside its ignores."""
    return state.resolve().parent / "bench-private-bank"


def reject_reserved_folder(tasks: Path) -> None:
    if any(p.is_dir() and p.name.casefold() == "private" for p in tasks.glob("*")):
        raise ValueError(f"In-repo task folder 'private' is reserved: {tasks / 'private'}")


def bank_files(tasks: Path) -> list[Path]:
    """Versioned bank bytes, excluding generated dependency/cache directories."""
    return sorted((p for p in tasks.rglob("*") if p.is_file()
                   and not any(part in IGNORED for part in p.relative_to(tasks).parts)),
                  key=lambda p: p.relative_to(tasks).as_posix())


def private_files(private: Path) -> list[Path]:
    """Enumerate private bytes without silently swallowing permission errors."""
    def fail(error: OSError) -> None:
        raise error
    if not private.exists():
        return []
    if not private.is_dir():
        raise OSError(f"Private bank is not a folder: {private}")
    files = []
    for directory, folders, names in os.walk(private, onerror=fail):
        folders[:] = [name for name in folders if name not in IGNORED]
        files.extend(Path(directory) / name for name in names
                     if name not in IGNORED and (Path(directory) / name).is_file())
    return sorted(files, key=lambda p: p.relative_to(private).as_posix())


def bank_hash(tasks: Path, private: Path | None = None) -> str:
    reject_reserved_folder(tasks)
    digest = hashlib.sha256()
    entries = [(p.relative_to(tasks).as_posix(), p.read_bytes()) for p in bank_files(tasks)]
    if private is not None:
        try:
            entries += [("private/" + p.relative_to(private).as_posix(), p.read_bytes())
                        for p in private_files(private)]
        except OSError:
            # An unavailable bank cannot retain its approved identity. Review and
            # reports explain the loss using the approval's private task ids.
            pass
    for relative, data in entries:
        name = relative.encode()
        digest.update(len(name).to_bytes(8, "big") + name)
        digest.update(len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()


def task_folders(tasks: Path, private: Path | None = None) -> dict[str, tuple[Path, bool]]:
    reject_reserved_folder(tasks)
    loaded = {p.parent.name: (p.parent, False) for p in sorted(tasks.glob("*/task.json"))}
    seen: set[str] = set()
    for task_id in loaded:
        if task_id.casefold() in seen:
            raise ValueError(f"Duplicate task id: {task_id}")
        seen.add(task_id.casefold())
    if private is not None:
        try:
            files = private_files(private)
            # Check readability before exposing a partially available bank.
            for path in files:
                path.read_bytes()
            folders = [p for p in private.iterdir() if p.is_dir() and p.name not in IGNORED] if private.exists() else []
        except OSError:
            files, folders = [], []
        for path in files:
            if path.name == "task.json" and len(path.relative_to(private).parts) != 2:
                raise ValueError(f"Private task.json is at an invalid depth in folder: {path.parent}")
        for folder in sorted(folders):
            path = folder / "task.json"
            if path not in files:
                raise ValueError(f"Private task folder has no parseable task.json: {folder}")
            try:
                task = json.loads(path.read_text(encoding="utf-8"))
            except (ValueError, UnicodeError) as error:
                raise ValueError(f"Invalid JSON in private task file: {path}") from error
            if not isinstance(task, dict) or any(key not in task for key in ("job", "grader", "category")):
                raise ValueError(f"Private task file must be an object with job, grader and category: {path}")
        for path in files:
            if path.name != "task.json" or len(path.relative_to(private).parts) != 2:
                continue
            task_id = path.parent.name
            if task_id.casefold() in seen:
                raise ValueError(f"Duplicate task id in in-repo and private banks: {task_id}")
            seen.add(task_id.casefold())
            loaded[task_id] = (path.parent, True)
    for task_id, (folder, _) in loaded.items():
        metadata = json.loads((folder / "task.json").read_text(encoding="utf-8"))
        if metadata.get("grader") == "ranked":
            tiers = metadata.get("tiers")
            if (not isinstance(tiers, list) or not tiers
                    or any(tier not in ("standard", "hard") for tier in tiers)):
                raise ValueError(f"Ranked task {task_id} must have a non-empty tiers list containing only standard or hard.")
    return dict(sorted(loaded.items()))


def private_bank_warning(tasks: Path, private: Path, approval: dict[str, Any]) -> str | None:
    if not approval.get("private_task_ids") or (not approval.get("private_bank_warning")
            and approval.get("task_bank_sha256") == bank_hash(tasks, private)):
        return None
    try:
        if not private.exists():
            raise FileNotFoundError(private)
        for path in private_files(private):
            path.read_bytes()
    except OSError:
        return f"The private bank folder {private.resolve()} is missing or unreadable; approval is reset."
    return None


def replace_with_retry(source: Path, target: Path) -> None:
    for attempt in range(5):
        try:
            source.replace(target)
            return
        except PermissionError:
            # Windows briefly denies the rename while a scanner holds the file.
            if attempt == 4:
                raise
            time.sleep(0.1 * (attempt + 1))


class Review:
    def __init__(self, tasks: Path, state: Path) -> None:
        self.tasks = tasks.resolve()
        self.state = state.resolve()
        self.private = private_bank_path(self.state.parent)
        self.approval_path = self.state / "golden-approval.json"
        self.artifact_path = self.state / "review" / f"{date.today().isoformat()}-golden-review.html"
        self.token = secrets.token_urlsafe(32)
        self.loaded = task_folders(self.tasks, self.private)
        self.ids = list(self.loaded)
        if not self.ids:
            raise ValueError("Task bank is empty")
        self.refresh()

    def save(self, value: dict[str, Any]) -> None:
        self.state.mkdir(parents=True, exist_ok=True)
        temporary = self.approval_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        replace_with_retry(temporary, self.approval_path)
        digest = bank_hash(self.tasks, self.private)
        hash_path = self.state / "bank-hash.json"
        temporary_hash = hash_path.with_suffix(".tmp")
        temporary_hash.write_text(json.dumps({"task_bank_sha256": digest,
                                             "written_at": datetime.now(timezone.utc).isoformat()}) + "\n", encoding="utf-8")
        replace_with_retry(temporary_hash, hash_path)

    def refresh(self) -> dict[str, Any]:
        self.loaded = task_folders(self.tasks, self.private)
        self.ids = list(self.loaded)
        if not self.ids:
            raise ValueError("Task bank is empty")
        current = bank_hash(self.tasks, self.private)
        try:
            value = json.loads(self.approval_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            value = {}
        if not isinstance(value, dict):
            value = {}
        warning = private_bank_warning(self.tasks, self.private, value)
        private_ids = [task_id for task_id, (_, is_private) in self.loaded.items() if is_private]
        covered_ids = value.get("private_task_ids", []) if warning else private_ids
        if value.get("task_bank_sha256") != current:
            value = {"schema_version": 1, "task_bank_sha256": current,
                     "dimension_framework": "provisional", "approved": False,
                     "tasks": {task_id: "pending" for task_id in self.ids}}
        value["private_task_ids"] = covered_ids
        value["private_bank_warning"] = warning
        choices = value.get("tasks", {})
        if not isinstance(choices, dict):
            choices = {}
        value["tasks"] = {task_id: choices.get(task_id, "pending") for task_id in self.ids}
        value["approved"] = all(choice == "approved" for choice in value["tasks"].values())
        if value["approved"]:
            value["private_task_ids"] = private_ids
            value["private_bank_warning"] = None
        self.save(value)
        self.artifact_path.parent.mkdir(parents=True, exist_ok=True)
        self.artifact_path.write_text(self.render(value), encoding="utf-8")
        return value

    def choose(self, task_id: str, choice: str, expected_hash: str) -> bool:
        value = self.refresh()
        if value["task_bank_sha256"] != expected_hash:
            return False
        if task_id not in self.ids or choice not in {"approved", "needs-change"}:
            raise ValueError("Invalid task or choice")
        value["tasks"][task_id] = choice
        value["approved"] = all(v == "approved" for v in value["tasks"].values())
        if value["approved"]:
            value["private_task_ids"] = [task_id for task_id, (_, is_private) in self.loaded.items() if is_private]
            value["private_bank_warning"] = None
        self.save(value)
        self.artifact_path.write_text(self.render(value), encoding="utf-8")
        return True

    def render(self, value: dict[str, Any]) -> str:
        sections = []
        for task_id in self.ids:
            task, is_private = self.loaded[task_id]
            metadata = json.loads((task / "task.json").read_text(encoding="utf-8"))
            parts = [f'<section id="{escape(task_id, quote=True)}"><h2>{escape(task_id)}{" (private)" if is_private else ""}</h2>',
                     f'<p>Category: {escape(str(metadata["category"]))} · Choice: '
                     f'<strong>{escape(value["tasks"][task_id])}</strong></p>']
            paths = [task / "prompt.md"]
            if metadata['grader'] == 'ranked':
                paths.append(task / 'criteria.md')
            paths += sorted(p for p in bank_files(task) if p.relative_to(task).parts[0] in {"fixtures", "golden"})
            for path in paths:
                parts.append(f'<details open><summary>{escape(path.relative_to(task).as_posix())}</summary>'
                             f'<pre>{escape(path.read_text(encoding="utf-8", errors="replace"))}</pre></details>')
            parts.append('<form method="post" action="/choice">')
            for name, content in {"csrf": self.token, "bank_hash": value["task_bank_sha256"], "task_id": task_id}.items():
                parts.append(f'<input type="hidden" name="{name}" value="{escape(content, quote=True)}">')
            parts.append('<button name="choice" value="approved">Approve</button> '
                         '<button name="choice" value="needs-change">Needs change</button></form></section>')
            sections.append("".join(parts))
        status = "Approved" if value["approved"] else "Pending golden review — shadow mode"
        return ('<!doctype html><html lang="en"><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width, initial-scale=1">'
                '<title>Internal bench golden review</title><style>'
                'body{font:16px system-ui;max-width:1100px;margin:2rem auto;padding:0 1rem;background:#fafafa;color:#222}'
                'section{border:1px solid #ccc;padding:1rem;margin:1rem 0;background:white}'
                'pre{white-space:pre-wrap;overflow-wrap:anywhere}button{padding:.6rem 1rem;margin:.5rem 0}'
                '.flow{display:block;width:100%;height:auto;margin:1rem 0;background:white;border:1px solid #ccc}'
                '.flow text{font:16px system-ui;fill:#222}.flow .node{fill:#f4f7fb;stroke:#334155;stroke-width:2}'
                '.flow .approved{fill:#e8f5e9;stroke:#216e39}.flow .changed{fill:#fff3e0;stroke:#8a4b08}'
                '.flow .edge{fill:none;stroke:#334155;stroke-width:2;marker-end:url(#arrow)}'
                '@media(max-width:600px){.flow{font-size:14px}.flow text{font-size:14px}}'
                '</style><h1>Internal bench golden review</h1>'
                f'<p id="status">{status}</p><p>Dimension framework: provisional</p>'
                + (f'<p>{escape(value["private_bank_warning"])}</p>' if value.get("private_bank_warning") else '') +
                f'<p>Bank SHA256: <code>{value["task_bank_sha256"]}</code></p>'
                '<p>Use the loopback review server to save choices. Each task requires your approval.</p>'
                '<svg class="flow" viewBox="0 0 960 300" role="img" aria-labelledby="flow-title flow-desc" '
                'xmlns="http://www.w3.org/2000/svg"><title id="flow-title">Golden review flow</title>'
                '<desc id="flow-desc">Each task starts pending and can be approved or marked needs change. '
                f'All {len(self.ids)} tasks approved makes the bank approved. Any bank byte or path edit resets every task to pending and returns the bank to shadow mode.</desc>'
                '<defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">'
                '<path d="M0,0 L0,6 L9,3 z" fill="#334155"/></marker></defs>'
                '<rect class="node" x="24" y="38" width="200" height="68" rx="10"/>'
                '<text x="124" y="79" text-anchor="middle">Per-task: pending</text>'
                '<path class="edge" d="M224 62 H304"/><path class="edge" d="M224 82 H264 V126 H304"/>'
                '<rect class="node approved" x="304" y="24" width="210" height="60" rx="10"/>'
                '<text x="409" y="61" text-anchor="middle">approved</text>'
                '<rect class="node changed" x="304" y="96" width="210" height="60" rx="10"/>'
                '<text x="409" y="133" text-anchor="middle">needs-change</text>'
                '<path class="edge" d="M514 54 H594"/>'
                '<rect class="node approved" x="594" y="24" width="340" height="60" rx="10"/>'
                f'<text x="764" y="61" text-anchor="middle">All {len(self.ids)} approved → bank approved</text>'
                '<path class="edge" d="M764 84 V190"/>'
                '<rect class="node changed" x="304" y="190" width="630" height="76" rx="10"/>'
                '<text x="619" y="222" text-anchor="middle">Any bank byte or path edit</text>'
                '<text x="619" y="246" text-anchor="middle">→ all tasks pending; bank returns to shadow mode</text>'
                '<path class="edge" d="M304 228 H124 V106"/></svg>'
                + "".join(sections) + '</html>')


def create_server(tasks: Path, state: Path, port: int = 0) -> HTTPServer:
    if port in {8792, 8802, 9222}:
        raise ValueError("Port reserved by another application")
    review = Review(tasks, state)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def respond(self, status: int, body: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(body.encode())

        def trusted_host(self) -> bool:
            return self.headers.get("Host") == f"127.0.0.1:{self.server.server_port}"

        def do_GET(self) -> None:
            if not self.trusted_host():
                self.respond(403, "Invalid host")
            elif self.path != "/":
                self.respond(404, "Not found")
            else:
                self.respond(200, review.render(review.refresh()))

        def do_POST(self) -> None:
            origin = f"http://127.0.0.1:{self.server.server_port}"
            if (not self.trusted_host() or self.headers.get("Origin") not in (None, origin)
                    or self.headers.get("Sec-Fetch-Site") == "cross-site"):
                self.respond(403, "Cross-origin write rejected")
                return
            if self.path != "/choice":
                self.respond(404, "Not found")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 8192 or self.headers.get("Content-Type", "").split(";")[0] != "application/x-www-form-urlencoded":
                    raise ValueError("Invalid request body")
                fields = parse_qs(self.rfile.read(length).decode("utf-8"), strict_parsing=True)
                if set(fields) != {"csrf", "bank_hash", "task_id", "choice"} or any(len(v) != 1 for v in fields.values()):
                    raise ValueError("Invalid fields")
                if not secrets.compare_digest(fields["csrf"][0], review.token):
                    self.respond(403, "Invalid CSRF token")
                    return
                if not review.choose(fields["task_id"][0], fields["choice"][0], fields["bank_hash"][0]):
                    self.respond(409, "Bank changed; reload the review before choosing")
                    return
            except (ValueError, UnicodeError):
                self.respond(400, "Invalid choice request")
                return
            self.send_response(303)
            self.send_header("Location", "/")
            self.end_headers()

    return HTTPServer(("127.0.0.1", port), Handler)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tasks", type=Path, default=TASKS)
    parser.add_argument("--state", type=Path, required=True, help="bench state folder (explicit; no live default)")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--generate-only", action="store_true")
    args = parser.parse_args()
    if args.generate_only:
        print(Review(args.tasks, args.state).artifact_path)
        return 0
    server = create_server(args.tasks, args.state, args.port)
    print(f"Golden review: http://127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
