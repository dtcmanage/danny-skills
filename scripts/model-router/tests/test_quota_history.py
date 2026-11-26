"""Quota ledger tests: injected vendor envelopes only, isolated DBs, no account access."""
import concurrent.futures
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
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
