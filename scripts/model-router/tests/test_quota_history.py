"""Quota ledger tests: injected vendor envelopes only, isolated DBs, no account access."""
import concurrent.futures
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("quota_history", ROOT / "quota_history.py")
qh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qh)


def payload(used=40, observed="2026-11-01T05:00:00Z", reset="2026-11-08T06:00:00Z", **kwargs):
    return dict(vendor="claude", source="oauth-usage", observed_at_utc=observed,
                collected_at_utc="2026-11-25T12:00:00Z", data={"seven_day": {"utilization": used, "resets_at": reset}}, **kwargs)


@pytest.mark.parametrize("used,reset,observed,kind", [
    (50, "2026-11-08T06:00:00Z", "2026-11-02T05:00:00Z", None),
    (2, "2026-11-15T06:00:00Z", "2026-11-08T07:00:00Z", "scheduled_consistent"),
    (2, "2026-11-09T06:00:00Z", "2026-11-02T05:00:00Z", "unexpected_drop_deadline_change"),
    (2, "2026-11-08T06:00:00Z", "2026-11-02T05:00:00Z", "unexpected_drop"),
    (40, "2026-11-09T06:00:00Z", "2026-11-02T05:00:00Z", "schedule_change"),
    (2, "2026-11-22T06:00:00Z", "2026-11-16T05:00:00Z", "scheduled_consistent"),
    (50, "2026-11-15T06:00:00Z", "2026-11-08T07:00:00Z", "schedule_change"),
])
def test_transitions(tmp_path, used, reset, observed, kind):
    qh.ingest(tmp_path, payload())
    qh.ingest(tmp_path, payload(used, observed, reset))
    events = qh.read_history(tmp_path, kind="event")
    assert [e["kind"] for e in events] == ([kind] if kind else [])
    if events:
        assert events[0]["cause"] == "unknown"
        assert events[0]["old_used_percent"] == 40
        assert events[0]["new_used_percent"] == used
        assert events[0]["interval_start_utc"] == qh.utc("2026-11-01T05:00:00Z")
        assert events[0]["old_reset_at_utc"] == qh.utc("2026-11-08T06:00:00Z")
    assert qh.ingest(tmp_path, payload(used, observed, reset))["duplicate"] == 1


def test_cached_duplicate_stale_correction_and_invalid(tmp_path):
    qh.ingest(tmp_path, payload())
    cached = payload(provenance="cache")
    cached["source"] = "cache"
    assert qh.ingest(tmp_path, cached)["duplicate"] == 1
    assert qh.ingest(tmp_path, payload(2))["stale"] == 1
    assert qh.ingest(tmp_path, payload(3, "2026-10-31T05:00:00Z"))["stale"] == 1
    assert qh.ingest(tmp_path, payload(-3, "2026-11-02T05:00:00Z"))["invalid"] == 1
    assert qh.ingest(tmp_path, payload(2, "2026-11-09T05:00:00Z"))["invalid"] == 1
    assert qh.ingest(tmp_path, payload(2, "2026-12-09T05:00:00Z", "2026-12-15T00:00:00Z"))["invalid"] == 1
    assert not qh.read_history(tmp_path, kind="event")
    qh.ingest(tmp_path, payload(50, "2026-11-03T05:00:00Z"))
    assert not qh.read_history(tmp_path, kind="event")


def test_missing_and_feature_windows(tmp_path):
    p = payload()
    p["data"].update(five_hour=None, seven_day_sonnet={"utilization": 5, "resets_at": None},
                     extra_usage={"is_enabled": True}, authorization="never-store", accessToken="never-store")
    qh.ingest(tmp_path, p)
    rows = qh.read_history(tmp_path)
    assert len(rows) == 3
    assert {r["limit_id"] for r in rows} == {"seven_day", "five_hour", "seven_day_sonnet"}
    assert next(r for r in rows if r["limit_id"] == "five_hour")["used_percent"] is None
    assert "never-store" not in json.dumps(rows)
    p["data"] = {}
    assert qh.ingest(tmp_path, p)["status"] == "no_windows"
    assert len(qh.read_history(tmp_path)) == 3


def test_codex_all_pools_and_dedupe_alias():
    window = dict(usedPercent=40, resetsAt=1794117600, windowDurationMins=10080)
    pool = dict(limitId="codex", limitName="shared", primary=window, secondary=None)
    p = payload()
    p.update(vendor="codex", source="codex-account-limits", data=dict(rateLimits=pool,
             rateLimitsByLimitId={"codex": pool, "feature-a": dict(primary=dict(window, windowDurationMins=300))}))
    rows = qh.normalize(p)
    assert len(rows) == 4  # two known windows and two explicitly unknown secondary windows
    assert {(r["limit_id"], r["window_id"]) for r in rows} == {
        ("codex", "minutes:10080"), ("codex", "secondary"), ("feature-a", "minutes:300"), ("feature-a", "secondary")}
    assert rows[0]["reported_scope"] == "shared"


def test_timezone_and_dst():
    assert qh.utc("2026-11-01T01:30:00-04:00") == "2026-11-01T05:30:00.000000+00:00"
    assert qh.utc("2026-11-01T01:30:00-05:00") == "2026-11-01T06:30:00.000000+00:00"
    assert qh.utc("2026-03-08T03:30:00-04:00") == "2026-03-08T07:30:00.000000+00:00"
    with pytest.raises(ValueError):
        qh.utc("2026-11-01T01:30:00")


def test_individual_spend_window_and_model_metadata():
    p = payload()
    p.update(vendor="codex", source="codex-account-limits", data={"rateLimits": {
        "limitId": "feature-b", "normalModelSlug": "reported-model", "primary": None,
        "individualLimit": {"remainingPercent": 80, "resetsAt": 1794117600, "used": "2", "limit": "10"}}})
    row = next(r for r in qh.normalize(p) if r["window_id"] == "individualLimit")
    assert row["used_percent"] == 20 and row["remaining_percent"] == 80
    assert row["metadata"]["limit"] == "10"


def test_archive_restart_and_backfill(tmp_path):
    p = payload(observed="2026-01-01T00:00:00Z", reset="2026-01-08T00:00:00Z", provenance="backfill")
    qh.ingest(tmp_path, p)
    assert qh.read_history(tmp_path) == []
    assert len(qh.read_history(tmp_path, True)) == 1
    assert qh.ingest(tmp_path, p)["duplicate"] == 1
    qh.ingest(tmp_path, payload(2, "2026-01-02T00:00:00Z", "2026-01-09T00:00:00Z", provenance="backfill"))
    assert qh.read_history(tmp_path, kind="event") == []
    assert len(qh.read_history(tmp_path, True, kind="event")) == 1
    qh.ingest(tmp_path, payload(1, "2026-11-01T05:00:00Z"))
    assert qh.read_history(tmp_path, kind="event")[0]["kind"] == "scheduled_consistent"
    assert len(qh.read_history(tmp_path, True)) == 3
    with sqlite3.connect(tmp_path / "quota-history.sqlite") as db:
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    for fmt in ("json", "csv", "summary"):
        result = subprocess.run([sys.executable, str(ROOT / "quota_history.py"), "--state-dir", str(tmp_path),
                                 "--include-archives", "--format", fmt], capture_output=True, text=True, check=True)
        assert "backfill" in result.stdout
        if fmt == "summary":
            assert "ET" in result.stdout and "UTC" not in result.stdout


@pytest.mark.parametrize("canonical,alias", [
    ("seven_day", "7d"), ("five_hour", "5h"),
    ("seven_day_sonnet", "7d-sonnet"), ("seven_day_opus", "7d-opus"),
    ("five_hour_sonnet", "5h-sonnet"), ("seven_day_feature_a", "7d-feature-a"),
    ("five_hour_feature_a", "five-hour-feature-a"), ("seven_day_feature_a", "seven-day-feature-a"),
])
def test_claude_source_alias_continuity(tmp_path, canonical, alias):
    def sample(name, used, observed, source):
        p = payload(used, observed)
        p.update(source=source, data={name: p["data"]["seven_day"]})
        return p
    first = sample(canonical, 80, "2026-11-01T05:00:00Z", "oauth-usage")
    qh.ingest(tmp_path, first)
    # Same value/timestamp across a source/credential-scope change is one immutable fact.
    assert qh.ingest(tmp_path, sample(alias, 80, first["observed_at_utc"], "inference-headers"))["duplicate"] == 1
    qh.ingest(tmp_path, sample(alias, 80, "2026-11-02T05:00:00Z", "inference-headers"))
    assert not qh.read_history(tmp_path, kind="event")
    qh.ingest(tmp_path, sample(alias, 5, "2026-11-03T05:00:00Z", "inference-headers"))
    event, = qh.read_history(tmp_path, kind="event")
    assert (event["kind"], event["limit_id"], event["window_id"], event["source"]) == (
        "unexpected_drop", canonical, canonical, "inference-headers")
    assert event["cause"] == "unknown" and event["old_used_percent"] == 80
    # Switching back to the endpoint keeps the same baseline and invents no event.
    qh.ingest(tmp_path, sample(canonical, 6, "2026-11-04T05:00:00Z", "oauth-usage"))
    assert len(qh.read_history(tmp_path, kind="event")) == 1
    rows = qh.read_history(tmp_path)
    assert {r["window_id"] for r in rows} == {canonical}
    assert rows[1]["metadata"]["vendor_window"] == alias
    assert rows[-1]["metadata"]["vendor_window"] == canonical
    assert qh.claude_window_id("unknown-slug") == "unknown-slug"


@pytest.mark.parametrize("kind", ["observation", "event"])
def test_archive_commit_between_actual_reads(tmp_path, monkeypatch, kind):
    qh.ingest(tmp_path, payload(80))
    qh.ingest(tmp_path, payload(5, "2026-11-02T05:00:00Z"))
    expected = qh.read_history(tmp_path, kind=kind)
    connect = sqlite3.connect
    moved = []
    def interleaved_connect(database, *args, **kwargs):
        if str(database).endswith("quota-history-archive.sqlite?mode=ro") and not moved:
            moved.append(True)
            # Exercise the real transactional writer after the active SELECT has finished.
            p = payload()
            p.update(collected_at_utc="2027-03-01T00:00:00Z", data={})
            qh.ingest(tmp_path, p)
        return connect(database, *args, **kwargs)
    monkeypatch.setattr(qh.sqlite3, "connect", interleaved_connect)
    assert qh.read_history(tmp_path, archives=True, kind=kind) == expected
    assert moved and not qh.read_history(tmp_path, kind=kind)


def test_actual_header_parser_preserves_model_window_names(tmp_path):
    script = tmp_path / "headers.ps1"
    script.write_text(""". $env:QUOTA_VENDOR_SCRIPT
ConvertFrom-RouterClaudeRateLimitHeaders -Headers @{
 'anthropic-ratelimit-unified-7d-sonnet-utilization'='0.05'
 'anthropic-ratelimit-unified-7d-sonnet-reset'='1794117600'
 'anthropic-ratelimit-unified-5h-utilization'='0.02'
 'anthropic-ratelimit-unified-5h-reset'='1794117600'
} | ConvertTo-Json -Depth 10 -Compress
""")
    env = dict(os.environ, QUOTA_VENDOR_SCRIPT=str(ROOT / "vendor-limits.ps1"))
    result = subprocess.run(["pwsh", "-NoProfile", "-File", str(script)], env=env, capture_output=True, text=True, check=True)
    p = payload()
    p.update(source="inference-headers", data=json.loads(result.stdout))
    rows = {r["window_id"]: r for r in qh.normalize(p)}
    assert rows["seven_day_sonnet"]["used_percent"] == 5
    assert rows["seven_day_sonnet"]["metadata"]["vendor_window"] == "7d-sonnet"
    assert rows["five_hour"]["metadata"]["vendor_window"] == "5h"


def test_concurrent_process_writes(tmp_path):
    command = [sys.executable, str(ROOT / "quota_history.py"), "--state-dir", str(tmp_path), "--ingest"]
    def run(_):
        return subprocess.run(command, input=json.dumps(payload()), text=True, capture_output=True, check=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(run, range(12)))
    assert sum(json.loads(r.stdout)["accepted"] for r in results) == 1
    assert len(qh.read_history(tmp_path)) == 1


def test_powershell_capture_and_observer(tmp_path):
    # Functions loaded in a fresh process: no globals shared with existing quota suites.
    script = tmp_path / "capture.ps1"
    script.write_text(""". $env:QUOTA_VENDOR_SCRIPT
function Get-RouterPlatform { return 'MacOS' }
Save-RouterQuotaObservation -Vendor claude -Source oauth-usage -Data ([pscustomobject]@{seven_day=$null})
if (Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'quota-history.sqlite')) { throw 'observer wrote' }
function Get-RouterPlatform { return 'Linux' }
Save-RouterQuotaObservation -Vendor claude -Source oauth-usage -Data ([pscustomobject]@{seven_day=[pscustomobject]@{utilization=40;resets_at='2027-01-08T00:00:00Z'}})
if ($script:RouterQuotaHistoryStatus -ne 'recorded') { throw 'capture failed' }
""")
    env = dict(os.environ, DT_MODEL_ROUTER_STATE=str(tmp_path / "state"), QUOTA_VENDOR_SCRIPT=str(ROOT / "vendor-limits.ps1"))
    subprocess.run(["pwsh", "-NoProfile", "-File", str(script)], env=env, text=True, capture_output=True, check=True)
    assert len(qh.read_history(tmp_path / "state")) == 1


def test_vendor_path_captures_before_synthetic_expiry(tmp_path):
    script = tmp_path / "expiry.ps1"
    script.write_text(""". $env:QUOTA_VENDOR_SCRIPT
$script:RouterClaudeCredentialProvider = { [pscustomobject]@{status='available';token='fixture';scopes=@('user:profile')} }
$script:RouterClaudeUsageFetcher = { [pscustomobject]@{
 seven_day=[pscustomobject]@{utilization=96;resets_at=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')}
 seven_day_sonnet=[pscustomobject]@{utilization=30;resets_at=[datetimeoffset]::UtcNow.AddDays(1).ToString('o')}
} }
$reading = Get-RouterClaudeUsage
if ($reading.used_percent -ne 0) { throw 'guard contract changed' }
$null = Get-RouterClaudeUsage
""")
    env = dict(os.environ, DT_MODEL_ROUTER_STATE=str(tmp_path / "state"), QUOTA_VENDOR_SCRIPT=str(ROOT / "vendor-limits.ps1"))
    subprocess.run(["pwsh", "-NoProfile", "-File", str(script)], env=env, capture_output=True, text=True, check=True)
    rows = qh.read_history(tmp_path / "state")
    assert len(rows) == 2
    weekly = next(r for r in rows if r["window_id"] == "seven_day")
    assert weekly["used_percent"] == 96 and weekly["status"] == "expired_source"
    assert not qh.read_history(tmp_path / "state", kind="event")


@pytest.mark.parametrize("claude_available,codex_available", [(True, True), (False, True), (True, False)])
def test_hourly_collector_independent_status_and_history(tmp_path, claude_available, codex_available):
    state = tmp_path / "state"
    # Retained facts must survive either vendor failing the new collection pass.
    qh.ingest(state, payload())
    script = tmp_path / "hourly.ps1"
    script.write_text(""". $env:QUOTA_VENDOR_SCRIPT
if ($env:FIXTURE_CLAUDE -eq '1') {
 Write-RouterJsonAtomic -Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'claude-usage.json') -Value ([pscustomobject]@{
  used_percent=40;resets_at_utc=[datetimeoffset]::UtcNow.AddDays(1).ToString('o');observed_at_utc=[datetimeoffset]::UtcNow.ToString('o')
  session_percent=$null;session_resets_at_utc=$null;source='oauth-usage';credential_locator_identity=(Get-RouterClaudeCredentialIdentity)
 })
}
& (Join-Path (Split-Path $env:QUOTA_VENDOR_SCRIPT) 'refresh-claude-usage.ps1') -Json
exit $LASTEXITCODE
""")
    env = dict(os.environ, DT_MODEL_ROUTER_STATE=str(state), QUOTA_VENDOR_SCRIPT=str(ROOT / "vendor-limits.ps1"),
               DT_MODEL_ROUTER_CLAUDE_CREDENTIALS=str(tmp_path / "missing-credential.json"),
               DT_MODEL_ROUTER_CODEX_LIVE_COMMAND=str(ROOT / "tests/fixtures/fake-codex-limits.py"),
               FIXTURE_CLAUDE="1" if claude_available else "0")
    env.pop("DT_ROUTER_TEST_FAKE_CLI_ROOT", None)
    env.pop("FAKE_CODEX_LIMITS_PERCENT", None)
    if codex_available:
        env["FAKE_CODEX_LIMITS_PERCENT"] = "20"
    result = subprocess.run(["pwsh", "-NoProfile", "-File", str(script)], env=env, capture_output=True, text=True)
    summary = json.loads(result.stdout)
    assert summary["fresh"] == claude_available
    assert summary["codex_status"] == ("fresh" if codex_available else "unavailable")
    assert result.returncode == (0 if claude_available and codex_available else 1)
    assert any(r["vendor"] == "claude" for r in qh.read_history(state))
    assert any(r["vendor"] == "codex" for r in qh.read_history(state)) == codex_available
    assert summary["claude_history_status"] == "no_observation"
    assert summary["codex_history_status"] == ("recorded" if codex_available else "no_observation")


@pytest.mark.parametrize("mode", ["fresh", "codex_failure", "history_lock"])
def test_hourly_fresh_fetch_and_history_lock_preserve_guard(tmp_path, mode):
    state = tmp_path / "state"
    qh.ingest(state, payload())
    retained = qh.read_history(state)
    now = datetime.now(timezone.utc)
    credentials = tmp_path / "credentials.json"
    credentials.write_text(json.dumps({"claudeAiOauth": {"accessToken": "fixture-never-store",
        "expiresAt": int((now + timedelta(hours=1)).timestamp() * 1000), "scopes": ["user:profile"]}}))
    response = tmp_path / "claude-response.json"
    response.write_text(json.dumps({"seven_day": {"utilization": 96, "resets_at": (now + timedelta(days=2)).isoformat()},
        "five_hour": {"utilization": 36, "resets_at": (now + timedelta(hours=2)).isoformat()}}))
    script = tmp_path / "hourly-fresh.ps1"
    script.write_text(""". $env:QUOTA_VENDOR_SCRIPT
function global:Invoke-RestMethod {
 param($Uri)
 if ($Uri -ne 'https://api.anthropic.com/api/oauth/usage') { throw 'unexpected fixture request' }
 Add-Content -LiteralPath $env:FIXTURE_FETCH_LOG -Value 'fetch'
 Get-Content -LiteralPath $env:FIXTURE_RESPONSE -Raw | ConvertFrom-Json -DateKind String
}
$summary = & (Join-Path (Split-Path $env:QUOTA_VENDOR_SCRIPT) 'refresh-claude-usage.ps1') -Json
$collectionExit = $LASTEXITCODE
$guards = @{claude=(Get-RouterVendorBlocked -Vendor claude);codex=(Get-RouterVendorBlocked -Vendor codex)}
@{summary=($summary | ConvertFrom-Json);guards=$guards} | ConvertTo-Json -Depth 10 -Compress
exit $collectionExit
""")
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    env = dict(os.environ, DT_MODEL_ROUTER_STATE=str(state), QUOTA_VENDOR_SCRIPT=str(ROOT / "vendor-limits.ps1"),
        DT_MODEL_ROUTER_CLAUDE_CREDENTIALS=str(credentials), DT_MODEL_ROUTER_CODEX_SESSIONS=str(sessions),
        DT_MODEL_ROUTER_CODEX_LIVE_COMMAND=str(ROOT / "tests/fixtures/fake-codex-limits.py"),
        FIXTURE_RESPONSE=str(response), FIXTURE_FETCH_LOG=str(tmp_path / "fetch.log"),
        FAKE_CODEX_LIMITS_PERCENT="20", FAKE_CODEX_LIMITS_SESSION_PERCENT="8", NO_COLOR="1")
    env.pop("DT_ROUTER_TEST_FAKE_CLI_ROOT", None)
    env.pop("DT_ROUTER_GUARD_OVERRIDE", None)
    if mode == "codex_failure":
        env.pop("FAKE_CODEX_LIMITS_PERCENT")
    lock = None
    try:
        if mode == "history_lock":
            # Real SQLite contention, with fail-fast busy handling only in the fixture
            # interpreter. The production collector, bridge, ingestion and SQL all run.
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            shim = bin_dir / "python3"
            shim.write_text(f"#!{sys.executable}\n" + """import os, runpy, sqlite3, sys
target, *args = sys.argv[1:]
sys.argv = [target, *args]
connect = sqlite3.connect
def immediate(*args, **kwargs):
    kwargs['timeout'] = 0
    return connect(*args, **kwargs)
sqlite3.connect = immediate
try:
    runpy.run_path(target, run_name='__main__')
except sqlite3.OperationalError as exc:
    with open(os.environ['FIXTURE_SQL_LOG'], 'a') as log:
        log.write(str(exc) + '\\n')
    raise
""")
            shim.chmod(0o755)
            env.update(PATH=str(bin_dir) + os.pathsep + env["PATH"], FIXTURE_SQL_LOG=str(tmp_path / "sql.log"))
            lock = sqlite3.connect(state / "quota-history.sqlite")
            lock.execute("BEGIN IMMEDIATE")
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(script)], env=env, capture_output=True, text=True)
    finally:
        if lock is not None:
            lock.rollback()
            lock.close()
    output = json.loads(result.stdout.splitlines()[-1])
    summary = output["summary"]
    assert result.returncode == (0 if mode == "fresh" else 1), result.stdout + result.stderr
    assert summary["fresh"] and summary["claude_status"] == "fresh_or_cache"
    assert summary["used_percent"] == 96 and summary["session_percent"] == 36
    assert summary["source"] == "oauth-usage"
    assert summary["codex_status"] == ("unavailable" if mode == "codex_failure" else "fresh")
    # History failures cannot turn a blocked Claude into available, or block Codex.
    assert output["guards"] == {"claude": True, "codex": False}
    assert (tmp_path / "fetch.log").read_text().splitlines() == ["fetch"]  # guard reused the cache
    rows = qh.read_history(state)
    assert all(row in rows for row in retained)
    if mode == "history_lock":
        assert summary["claude_history_status"] == summary["codex_history_status"] == "error"
        assert rows == retained and not qh.read_history(state, kind="event")
        assert (tmp_path / "sql.log").read_text().splitlines() == ["database is locked"] * 2
        assert "QUOTA_HISTORY_WRITE_FAILED" in result.stdout
    else:
        assert summary["claude_history_status"] == "recorded"
        fresh_claude = [r for r in rows if r["vendor"] == "claude" and r not in retained]
        assert {(r["window_id"], r["source"], r["used_percent"]) for r in fresh_claude} == {
            ("five_hour", "oauth-usage", 36), ("seven_day", "oauth-usage", 96)}
        assert all(r["provenance"] == "fresh" for r in fresh_claude)
        codex = [r for r in rows if r["vendor"] == "codex"]
        if mode == "fresh":
            assert summary["codex_history_status"] == "recorded"
            assert {(r["window_id"], r["source"], r["used_percent"]) for r in codex} == {
                ("minutes:10080", "codex-account-limits", 20), ("minutes:300", "codex-account-limits", 8)}
        else:
            assert summary["codex_history_status"] == "no_observation" and not codex
    assert "fixture-never-store" not in json.dumps(rows)
