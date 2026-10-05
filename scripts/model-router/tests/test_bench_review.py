from __future__ import annotations

import http.client
import importlib.util
import json
from pathlib import Path
import re
import shutil
import threading
from urllib.parse import urlencode

import pytest

BENCH = Path(__file__).resolve().parents[1] / "bench"
spec = importlib.util.spec_from_file_location("bench_review", BENCH / "review.py")
assert spec and spec.loader
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


@pytest.fixture
def service(tmp_path: Path):
    tasks = tmp_path / "tasks"
    shutil.copytree(BENCH / "tasks", tasks, ignore=shutil.ignore_patterns("node_modules", "__pycache__", ".pytest_cache"))
    state = tmp_path / "state/bench"
    server = review.create_server(tasks, state, 0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server, tasks, state
    server.shutdown()
    thread.join(timeout=5)
    server.server_close()


def request(server, method: str, path: str = "/", body: str | None = None,
            extra: dict[str, str] | None = None) -> tuple[int, str]:
    conn = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    headers.update(extra or {})
    conn.request(method, path, body, headers)
    response = conn.getresponse()
    result = response.status, response.read().decode()
    conn.close()
    return result


def form(server, task_id: str, choice: str) -> dict[str, str]:
    status, html = request(server, "GET")
    assert status == 200
    values = dict(re.findall(r'name="(csrf|bank_hash)" value="([^"]+)"', html))
    return {**values, "task_id": task_id, "choice": choice}


def stored(state: Path) -> dict:
    return json.loads((state / "golden-approval.json").read_text())


def test_http_choices_and_restart(service):
    server, tasks, state = service
    assert server.server_address[0] == "127.0.0.1"
    ids = sorted(p.parent.name for p in tasks.glob("*/task.json"))
    assert not stored(state)["approved"]
    assert request(server, "POST", "/choice", urlencode(form(server, ids[0], "needs-change")))[0] == 303
    assert stored(state)["tasks"][ids[0]] == "needs-change"
    assert review.Review(tasks, state).refresh()["tasks"][ids[0]] == "needs-change"
    for task_id in ids[1:]:
        assert request(server, "POST", "/choice", urlencode(form(server, task_id, "approved")))[0] == 303
    assert not stored(state)["approved"]
    assert request(server, "POST", "/choice", urlencode(form(server, ids[0], "approved")))[0] == 303
    assert stored(state)["approved"]
    assert review.Review(tasks, state).refresh()["approved"]


@pytest.mark.parametrize("relative", ["prompt.md", "fixtures/input.json", "golden/rubric.json", "grader.py"])
def test_hash_invalidation_regenerates_and_rejects_stale_choice(service, relative):
    server, tasks, state = service
    fields = form(server, "analysis-ddq-gaps", "approved")
    assert request(server, "POST", "/choice", urlencode(fields))[0] == 303
    path = tasks / "analysis-ddq-gaps" / relative
    path.write_text(path.read_text() + "\n")
    assert request(server, "POST", "/choice", urlencode(fields))[0] == 409
    value = stored(state)
    assert not value["approved"]
    assert set(value["tasks"].values()) == {"pending"}
    assert value["task_bank_sha256"] != fields["bank_hash"]
    html = next((state / "review").glob("*.html")).read_text(encoding="utf-8")
    assert value["task_bank_sha256"] in html


def test_cross_origin_csrf_and_invalid_choices(service):
    server, tasks, state = service
    fields = form(server, "analysis-ddq-gaps", "approved")
    for headers in ({"Origin": "https://example.org"}, {"Host": "evil.example"}, {"Sec-Fetch-Site": "cross-site"}):
        assert request(server, "POST", "/choice", urlencode(fields), headers)[0] == 403
    assert request(server, "POST", "/choice", urlencode({**fields, "csrf": "bad"}))[0] == 403
    for changes in ({"choice": "yes"}, {"task_id": "../outside"}):
        assert request(server, "POST", "/choice", urlencode({**fields, **changes}))[0] == 400
    assert set(stored(state)["tasks"].values()) == {"pending"}


def test_escaped_data_and_cache_hash(service):
    server, tasks, state = service
    attack = '<script>alert("x")</script><form action="https://evil">'
    task = tasks / "analysis-ddq-gaps"
    for relative in ("prompt.md", "fixtures/input.json", "golden/answer.md"):
        (task / relative).write_text(attack, encoding="utf-8")
    status, html = request(server, "GET")
    assert status == 200 and attack not in html
    assert html.count("&lt;script&gt;") == 3
    before = review.bank_hash(tasks)
    cache = tasks / "__pycache__/junk.pyc"
    cache.parent.mkdir(exist_ok=True)
    cache.write_bytes(b"cache")
    assert review.bank_hash(tasks) == before


def test_render_includes_accessible_review_flow(service):
    server, tasks, state = service
    status, html = request(server, "GET")
    assert status == 200
    assert '<svg class="flow"' in html and 'role="img"' in html
    assert 'aria-labelledby="flow-title flow-desc"' in html
    assert '<path class="edge" d="M224 82 H264 V126 H304"/>' in html
    count = len(list(Path(tasks).glob("*/task.json")))
    for transition in (
        "Per-task: pending", "approved", "needs-change",
        f"All {count} approved → bank approved",
        "Any bank byte or path edit", "all tasks pending; bank returns to shadow mode",
    ):
        assert transition in html


@pytest.mark.parametrize("port", [8792, 8802, 9222])
def test_reserved_ports(tmp_path: Path, port: int):
    with pytest.raises(ValueError, match="reserved"):
        review.create_server(BENCH / "tasks", tmp_path, port)
