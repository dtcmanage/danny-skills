"""Loopback golden review. Callers supply isolated or live state explicitly.

No alerts, browser launches, or implicit approvals. A bank edit resets every choice.
"""
from __future__ import annotations

import argparse
from datetime import date
import hashlib
from html import escape
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import secrets
from typing import Any
from urllib.parse import parse_qs


TASKS = Path(__file__).resolve().parent / "tasks"
IGNORED = {"node_modules", "__pycache__", ".pytest_cache"}


def bank_files(tasks: Path) -> list[Path]:
    """Versioned bank bytes, excluding generated dependency/cache directories."""
    return sorted((p for p in tasks.rglob("*") if p.is_file()
                   and not any(part in IGNORED for part in p.relative_to(tasks).parts)),
                  key=lambda p: p.relative_to(tasks).as_posix())


def bank_hash(tasks: Path) -> str:
    digest = hashlib.sha256()
    for path in bank_files(tasks):
        name = path.relative_to(tasks).as_posix().encode()
        data = path.read_bytes()
        digest.update(len(name).to_bytes(8, "big") + name)
        digest.update(len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()


class Review:
    def __init__(self, tasks: Path, state: Path) -> None:
        self.tasks = tasks.resolve()
        self.state = state.resolve()
        self.approval_path = self.state / "golden-approval.json"
        self.artifact_path = self.state / "review" / f"{date.today().isoformat()}-golden-review.html"
        self.token = secrets.token_urlsafe(32)
        self.ids = sorted(p.parent.name for p in self.tasks.glob("*/task.json"))
        if not self.ids:
            raise ValueError("Task bank is empty")
        self.refresh()

    def save(self, value: dict[str, Any]) -> None:
        self.state.mkdir(parents=True, exist_ok=True)
        temporary = self.approval_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        temporary.replace(self.approval_path)

    def refresh(self) -> dict[str, Any]:
        self.ids = sorted(p.parent.name for p in self.tasks.glob("*/task.json"))
        if not self.ids:
            raise ValueError("Task bank is empty")
        current = bank_hash(self.tasks)
        try:
            value = json.loads(self.approval_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            value = {}
        if not isinstance(value, dict) or value.get("task_bank_sha256") != current:
            value = {"schema_version": 1, "task_bank_sha256": current,
                     "dimension_framework": "provisional", "approved": False,
                     "tasks": {task_id: "pending" for task_id in self.ids}}
        choices = value.get("tasks", {})
        if not isinstance(choices, dict):
            choices = {}
        value["tasks"] = {task_id: choices.get(task_id, "pending") for task_id in self.ids}
        value["approved"] = all(choice == "approved" for choice in value["tasks"].values())
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
        self.save(value)
        self.artifact_path.write_text(self.render(value), encoding="utf-8")
        return True

    def render(self, value: dict[str, Any]) -> str:
        sections = []
        for task_id in self.ids:
            task = self.tasks / task_id
            metadata = json.loads((task / "task.json").read_text(encoding="utf-8"))
            parts = [f'<section id="{escape(task_id, quote=True)}"><h2>{escape(task_id)}</h2>',
                     f'<p>Category: {escape(str(metadata["category"]))} · Choice: '
                     f'<strong>{escape(value["tasks"][task_id])}</strong></p>']
            paths = [task / "prompt.md"]
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
                f'<p>Bank SHA256: <code>{value["task_bank_sha256"]}</code></p>'
                '<p>Use the loopback review server to save choices. Each task requires your approval.</p>'
                '<svg class="flow" viewBox="0 0 960 300" role="img" aria-labelledby="flow-title flow-desc" '
                'xmlns="http://www.w3.org/2000/svg"><title id="flow-title">Golden review flow</title>'
                '<desc id="flow-desc">Each task starts pending and can be approved or marked needs change. '
                'All 18 tasks approved makes the bank approved. Any bank byte or path edit resets every task to pending and returns the bank to shadow mode.</desc>'
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
                '<text x="764" y="61" text-anchor="middle">All 18 approved → bank approved</text>'
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
