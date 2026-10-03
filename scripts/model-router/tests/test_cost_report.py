"""Tests for the M07 API-equivalent cost report: cost_report.py plus the
--all-sessions extension to skills/dt-build/scripts/collect-usage.py.

pytest, fixtures only. No network, no model calls, DT_MODEL_ROUTER_STATE always points
at a pytest tmp_path.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
COLLECT_USAGE_PATH = REPO_ROOT / "skills" / "dt-build" / "scripts" / "collect-usage.py"
BASELINE_PATH = Path(__file__).resolve().parent / "fixtures" / "collect-usage-baseline.py"

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import cost_report as cr  # noqa: E402


def _load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def cu():
    return _load_module(COLLECT_USAGE_PATH, "collect_usage_under_test")


UTC = timezone.utc


def _iso(dt: datetime) -> str:
    return dt.astimezone(UTC).isoformat().replace("+00:00", "Z")


# ---------------------------------------------------------------------------
# Pricing math per token type, both vendors
# ---------------------------------------------------------------------------

SYNTH_PRICES = {
    "schema_version": 1,
    "models": {
        "claude-test-model": {
            "vendor": "anthropic",
            "prices_usd_per_mtok": {"input": 10, "cache_write": 12.5, "cache_read": 1, "output": 50},
        },
        "gpt-test-model": {
            "vendor": "openai",
            "prices_usd_per_mtok": {"input": 10, "cache_write": 12.5, "cached_input": 1, "output": 50},
        },
        "claude-unpriced-field": {
            "vendor": "anthropic",
            "prices_usd_per_mtok": {"input": None, "cache_write": None, "cache_read": None, "output": None},
        },
    },
    "subscriptions": {
        "claude_max": {"weekly_usd": 46.153846153846154},
        "chatgpt_pro": {"weekly_usd": 46.153846153846154},
    },
}


def test_anthropic_pricing_math_per_token_type():
    row = {"host": "claude", "model": "claude-test-model",
           "tokens": {"input": 1_000_000, "cache_write": 1_000_000, "cache_read": 1_000_000, "output": 1_000_000}}
    cost, tokens = cr.price_usage_row(row, SYNTH_PRICES)
    assert cost == pytest.approx(10 + 12.5 + 1 + 50)
    assert tokens == row["tokens"]


def test_openai_pricing_math_prices_cache_write_separately():
    row = {"host": "codex", "model": "gpt-test-model",
           "tokens": {"input": 500_000, "cache_write": 500_000, "cache_read": 1_000_000, "output": 1_000_000}}
    cost, _ = cr.price_usage_row(row, SYNTH_PRICES)
    assert cost == pytest.approx(5 + 6.25 + 1 + 50)


def test_openai_missing_cache_write_rate_is_unpriced():
    prices = json.loads(json.dumps(SYNTH_PRICES))
    del prices['models']['gpt-test-model']['prices_usd_per_mtok']['cache_write']
    row = {'host':'codex','model':'gpt-test-model','tokens':{'input':5,'cache_write':5,'cache_read':0,'output':1}}
    assert cr.price_usage_row(row, prices)[0] is None
    row['tokens']['cache_write'] = 0
    assert cr.price_usage_row(row, prices)[0] == pytest.approx(0.0001)


@pytest.mark.parametrize('model,host', [('gpt-test-model','codex'), ('claude-test-model','claude')])
@pytest.mark.parametrize('bad', [None, True, False, -1, float('nan'), float('inf'), '1'])
def test_invalid_cache_write_rates_are_unpriced(model, host, bad):
    prices = json.loads(json.dumps(SYNTH_PRICES))
    prices['models'][model]['prices_usd_per_mtok']['cache_write'] = bad
    row = {'host':host,'model':model,'tokens':{'input':5,'cache_write':5,'cache_read':0,'output':1}}
    cost, tokens = cr.price_usage_row(row, prices)
    assert cost is None and tokens == row['tokens']


@pytest.mark.parametrize('bad', [None, True, False, -1, float('nan'), float('inf'), '1'])
def test_zero_cache_writes_ignore_unused_invalid_rate(bad):
    prices = json.loads(json.dumps(SYNTH_PRICES))
    prices['models']['gpt-test-model']['prices_usd_per_mtok']['cache_write'] = bad
    row = {'host':'codex','model':'gpt-test-model','tokens':{'input':5,'cache_write':0,'cache_read':0,'output':1}}
    assert cr.price_usage_row(row, prices)[0] == pytest.approx(0.0001)


def test_unpriced_model_reported_not_zeroed():
    row = {"host": "claude", "model": "claude-nonexistent-model",
           "tokens": {"input": 100, "cache_write": 0, "cache_read": 0, "output": 10}}
    cost, tokens = cr.price_usage_row(row, SYNTH_PRICES)
    assert cost is None
    assert tokens == row["tokens"]  # tokens still returned, not dropped


def test_unpriced_null_price_field_also_unpriced_not_zero_cost():
    row = {"host": "claude", "model": "claude-unpriced-field",
           "tokens": {"input": 100, "cache_write": 0, "cache_read": 0, "output": 10}}
    cost, _ = cr.price_usage_row(row, SYNTH_PRICES)
    assert cost is None


def test_resolve_price_key_prefix_match_for_snapshot_suffix():
    models = {"claude-fable-5-1": {}}
    assert cr.resolve_price_key("claude-fable-5-1-20260915", models) == "claude-fable-5-1"
    assert cr.resolve_price_key("claude-fable-5-1", models) == "claude-fable-5-1"
    assert cr.resolve_price_key("claude-fable-5-10", models) is None  # not a real suffix boundary
    assert cr.resolve_price_key(None, models) is None


def test_unpriced_bucket_reported_by_vendor_week():
    rows = [
        {"host": "claude", "session_id": "s1", "model": "claude-nonexistent-model", "date_et": "2026-09-21",
         "tokens": {"input": 100, "cache_write": 0, "cache_read": 0, "output": 10}},
    ]
    vw = cr.build_vendor_week("claude", 2026, 39, rows, [], SYNTH_PRICES, date(2026, 9, 27))
    assert vw.api_equivalent_usd == 0.0
    assert "claude-nonexistent-model" in vw.unpriced_tokens_by_model
    assert vw.unpriced_tokens_by_model["claude-nonexistent-model"]["input"] == 100


def test_work_by_model_shares_and_unpriced_rows(tmp_path):
    frontier_path = tmp_path / "frontier.json"
    frontier_path.write_text('{"codex_models": [], "claude_patterns": []}', encoding="utf-8")
    rows = [
        {"host": "claude", "session_id": "shared", "model": "claude-test-model", "date_et": "2026-09-21",
         "calls": 2, "tokens": {"input": 1_000_000}},
        {"host": "claude", "session_id": "shared", "model": "claude-test-model", "date_et": "2026-09-22",
         "calls": 1, "tokens": {"input": 1_000_000}},
        {"host": "codex", "session_id": "shared", "model": "gpt-test-model", "date_et": "2026-09-21",
         "calls": 4, "tokens": {"input": 1_000_000}},
        {"host": "codex", "session_id": "other", "model": "gpt-unknown", "date_et": "2026-09-21",
         "calls": 3, "tokens": {"input": 1_000_000}},
    ]
    report = cr.build_weekly_reports(rows, [], SYNTH_PRICES, date(2026, 9, 27), frontier_path)[0]
    by_model = {item["model"]: item for item in report["work_by_model"]}
    assert [item["model"] for item in report["work_by_model"]] == [
        "claude-test-model", "gpt-test-model", "gpt-unknown"]
    assert by_model["claude-test-model"]["sessions"] == 1
    assert by_model["claude-test-model"]["calls"] == 3
    assert by_model["gpt-test-model"]["sessions"] == 1
    assert by_model["gpt-test-model"]["calls"] == 4
    assert sum(item["share_pct"] for item in report["work_by_model"] if item["share_pct"] is not None) == pytest.approx(100)
    assert by_model["gpt-unknown"]["api_equivalent_usd"] is None
    assert by_model["gpt-unknown"]["share_pct"] is None
    assert "gpt-unknown: 1 sessions, 3 calls, unpriced" in cr.render_markdown(report)
    assert "gpt-unknown: 1 sessions, 3 calls, unpriced" in cr.render_html(report)


def test_frontier_exact_id_and_claude_glob_from_file(tmp_path):
    frontier_path = tmp_path / "frontier.json"
    frontier_path.write_text(json.dumps({"codex_models": ["gpt-test-model"],
                                         "claude_patterns": ["claude-test-*"]}), encoding="utf-8")
    rows = [
        {"host": "codex", "session_id": "same", "model": "gpt-test-model", "date_et": "2026-09-21",
         "calls": 1, "tokens": {"input": 1_000_000}},
        {"host": "claude", "session_id": "same", "model": "claude-test-model", "date_et": "2026-09-21",
         "calls": 1, "tokens": {"input": 1_000_000}},
        {"host": "codex", "session_id": "other", "model": "gpt-test-model-suffix", "date_et": "2026-09-21",
         "calls": 1, "tokens": {"input": 1_000_000}},
    ]
    report = cr.build_weekly_reports(rows, [], SYNTH_PRICES, date(2026, 9, 27), frontier_path)[0]
    assert report["frontier"]["model_ids"] == ["claude-test-model", "gpt-test-model"]
    assert report["frontier"]["sessions"] == 2
    assert report["frontier"]["api_equivalent_usd"] == pytest.approx(20)
    for rendered in (cr.render_markdown(report), cr.render_html(report)):
        assert "Work by model" in rendered
        assert "Frontier models used: claude-test-model, gpt-test-model, $20.00 API-equivalent across 2 sessions" in rendered


def test_no_frontier_models_line_in_both_formats(tmp_path):
    frontier_path = tmp_path / "frontier.json"
    frontier_path.write_text('{"codex_models": [], "claude_patterns": []}', encoding="utf-8")
    rows = [{"host": "codex", "session_id": "s1", "model": "gpt-test-model", "date_et": "2026-09-21",
             "calls": 1, "tokens": {"input": 1_000_000}}]
    report = cr.build_weekly_reports(rows, [], SYNTH_PRICES, date(2026, 9, 27), frontier_path)[0]
    for rendered in (cr.render_markdown(report), cr.render_html(report)):
        assert "Work by model" in rendered
        assert "gpt-test-model: 1 sessions, 1 calls" in rendered
        assert "Frontier models: none this week" in rendered


# ---------------------------------------------------------------------------
# Week boundaries in ET
# ---------------------------------------------------------------------------

def test_iso_week_of_and_label():
    assert cr.iso_week_of("2026-09-21") == (2026, 39)  # Monday of that ISO week
    assert cr.week_label(2026, 39) == "2026-W39"


def test_week_bounds_et_monday_to_sunday():
    monday, sunday = cr.week_bounds_et(2026, 39)
    assert monday.isoweekday() == 1
    assert sunday.isoweekday() == 7
    assert (sunday - monday).days == 6


def test_to_et_date_buckets_by_eastern_not_utc(cu):
    # 2026-09-21 03:30 UTC is 2026-09-20 23:30 ET (EDT, UTC-4) -- a UTC-day boundary
    # that must NOT bleed into the next ET calendar day/week.
    assert cu.to_et_date("2026-09-21T03:30:00Z") == "2026-09-20"


def test_week_bounds_utc_spans_seven_days():
    start, end = cr.week_bounds_utc(2026, 39)
    assert (end - start) == timedelta(days=7)


# ---------------------------------------------------------------------------
# Blocked-time interval math (Codex only; never invented for Claude)
# ---------------------------------------------------------------------------

def test_blocked_interval_ends_at_next_reading_below_100():
    t0 = datetime(2026, 9, 22, 10, 0, tzinfo=UTC)
    readings = [
        {"ts": _iso(t0), "used_percent": 90, "resets_at": None},
        {"ts": _iso(t0 + timedelta(minutes=5)), "used_percent": 100, "resets_at": int((t0 + timedelta(hours=5)).timestamp())},
        {"ts": _iso(t0 + timedelta(minutes=20)), "used_percent": 100, "resets_at": int((t0 + timedelta(hours=5)).timestamp())},
        {"ts": _iso(t0 + timedelta(minutes=30)), "used_percent": 40, "resets_at": int((t0 + timedelta(hours=5)).timestamp())},
    ]
    intervals = cr.compute_blocked_intervals(readings)
    assert len(intervals) == 1
    start, end = intervals[0]
    assert start == t0 + timedelta(minutes=5)
    assert end == t0 + timedelta(minutes=30)  # ends at the reading that dropped below 100, before resets_at


def test_blocked_interval_ends_at_resets_at_when_earlier_than_next_reading():
    t0 = datetime(2026, 9, 22, 10, 0, tzinfo=UTC)
    reset_time = t0 + timedelta(minutes=10)
    readings = [
        {"ts": _iso(t0), "used_percent": 100, "resets_at": int(reset_time.timestamp())},
        {"ts": _iso(t0 + timedelta(hours=2)), "used_percent": 100, "resets_at": int(reset_time.timestamp())},
    ]
    intervals = cr.compute_blocked_intervals(readings)
    assert len(intervals) == 1
    start, end = intervals[0]
    assert start == t0
    assert end == reset_time


def test_overlap_minutes_clips_to_week_window():
    start = datetime(2026, 9, 21, 0, 0, tzinfo=UTC)
    end = start + timedelta(days=7)
    intervals = [(start - timedelta(hours=1), start + timedelta(hours=1))]  # straddles week start
    assert cr.overlap_minutes(intervals, start, end) == pytest.approx(60.0)


def test_no_invented_claude_blocked_figure():
    vw = cr.build_vendor_week("claude", 2026, 39, [], [], SYNTH_PRICES, date(2026, 9, 27))
    assert vw.blocked_minutes is None


def test_codex_blocked_minutes_computed_when_rate_rows_present():
    t0 = datetime(2026, 9, 22, 10, 0, tzinfo=UTC)
    rate_rows = [
        {"ts": _iso(t0), "used_percent": 100, "resets_at": int((t0 + timedelta(minutes=30)).timestamp())},
    ]
    vw = cr.build_vendor_week("codex", 2026, 39, [], rate_rows, SYNTH_PRICES, date(2026, 9, 27))
    assert vw.blocked_minutes == pytest.approx(30.0)


# ---------------------------------------------------------------------------
# Coverage labels
# ---------------------------------------------------------------------------

def test_coverage_gap_when_a_weekday_is_missing():
    rows = [
        {"host": "claude", "session_id": "s1", "model": "claude-test-model", "date_et": d,
         "tokens": {"input": 10, "cache_write": 0, "cache_read": 0, "output": 1}}
        for d in ("2026-09-21", "2026-09-22", "2026-09-24")  # skip 09-23
    ]
    vw = cr.build_vendor_week("claude", 2026, 39, rows, [], SYNTH_PRICES, date(2026, 9, 27))
    assert vw.coverage_complete is False
    assert "2026-09-23" in vw.gap_dates
    assert vw.dates_seen == ["2026-09-21", "2026-09-22", "2026-09-24"]


def test_coverage_complete_when_no_gap_through_today():
    rows = [
        {"host": "claude", "session_id": "s1", "model": "claude-test-model", "date_et": d,
         "tokens": {"input": 10, "cache_write": 0, "cache_read": 0, "output": 1}}
        for d in ("2026-09-21", "2026-09-22")
    ]
    # "today" is the same week and clamps expected days to 09-21..09-22
    vw = cr.build_vendor_week("claude", 2026, 39, rows, [], SYNTH_PRICES, date(2026, 9, 22))
    assert vw.coverage_complete is True
    assert vw.gap_dates == []


# ---------------------------------------------------------------------------
# collect-usage.py --all-sessions: Claude subagent counting, dedupe
# ---------------------------------------------------------------------------

def _write_claude_session(root: Path, project: str, session_id: str, lines: list[dict]) -> Path:
    proj_dir = root / project
    proj_dir.mkdir(parents=True, exist_ok=True)
    path = proj_dir / f"{session_id}.jsonl"
    path.write_text("".join(json.dumps(l) + "\n" for l in lines), encoding="utf-8")
    return path


def _assistant_line(ts: str, mid: str, model: str, usage: dict) -> dict:
    return {"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": model, "usage": usage, "content": []}}


def test_claude_subagent_files_counted(cu, tmp_path):
    claude_home = tmp_path / "claude"
    session_id = "sess-sub-1"
    _write_claude_session(claude_home / "projects", "proj-a", session_id, [
        {"type": "user", "timestamp": "2026-09-21T14:00:00Z", "message": {"content": "hello"}},
        _assistant_line("2026-09-21T14:01:00Z", "m1", "claude-fable-5-1",
                         {"input_tokens": 100, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 20}),
    ])
    sub_dir = claude_home / "projects" / "proj-a" / session_id / "subagents"
    sub_dir.mkdir(parents=True)
    (sub_dir / "sub1.jsonl").write_text("".join(json.dumps(l) + "\n" for l in [
        _assistant_line("2026-09-21T14:02:00Z", "sub-m1", "claude-fable-5-1",
                         {"input_tokens": 50, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 10}),
    ]), encoding="utf-8")

    main_path = claude_home / "projects" / "proj-a" / f"{session_id}.jsonl"
    rows = cu.all_sessions_claude_rows(main_path)
    assert len(rows) == 1
    row = rows[0]
    assert row["tokens"]["input"] == 150  # 100 main + 50 subagent
    assert row["tokens"]["output"] == 30
    assert row["session_id"] == session_id


def test_claude_message_id_dedupe_within_file(cu, tmp_path):
    claude_home = tmp_path / "claude"
    session_id = "sess-dedupe"
    line = _assistant_line("2026-09-21T14:01:00Z", "dupe-id", "claude-fable-5-1",
                            {"input_tokens": 100, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 20})
    path = _write_claude_session(claude_home / "projects", "proj-a", session_id, [
        {"type": "user", "timestamp": "2026-09-21T14:00:00Z", "message": {"content": "hello"}},
        line, line,  # repeated verbatim, as a resumed transcript can do
    ])
    rows = cu.all_sessions_claude_rows(path)
    assert len(rows) == 1
    assert rows[0]["tokens"]["input"] == 100  # not 200
    assert rows[0]["calls"] == 1


# ---------------------------------------------------------------------------
# Codex: last_token_usage deltas + model attribution across a mid-session model change
# ---------------------------------------------------------------------------

def _codex_rollout(path: Path, session_id: str, events: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(e) + "\n" for e in events), encoding="utf-8")


def test_codex_uses_last_token_usage_not_cumulative_total(cu, tmp_path):
    codex_home = tmp_path / "codex"
    path = codex_home / "sessions" / "2026" / "09" / "21" / "rollout-abc.jsonl"
    events = [
        {"type": "session_meta", "timestamp": "2026-09-21T10:00:00Z", "payload": {"id": "codex-sess-1", "type": "session_meta"}},
        {"type": "turn_context", "timestamp": "2026-09-21T10:00:01Z", "payload": {"type": "turn_context", "model": "gpt-6-astra"}},
        {"type": "event_msg", "timestamp": "2026-09-21T10:01:00Z", "payload": {
            "type": "token_count",
            "info": {"total_token_usage": {"input_tokens": 900000, "cached_input_tokens": 0, "output_tokens": 400000},
                      "last_token_usage": {"input_tokens": 1000, "cached_input_tokens": 200, "output_tokens": 300}},
            "rate_limits": {"primary": {"used_percent": 12.0, "window_minutes": 10080, "resets_at": 1791050544}},
        }},
    ]
    _codex_rollout(path, "codex-sess-1", events)
    usage_rows, rate_rows = cu.all_sessions_codex_rows(path)
    assert len(usage_rows) == 1
    row = usage_rows[0]
    # Uses the small per-turn delta, never the huge cumulative total.
    assert row["tokens"]["input"] == 800  # 1000 - 200 cached
    assert row["tokens"]["cache_read"] == 200
    assert row["tokens"]["output"] == 300
    assert row["model"] == "gpt-6-astra"
    assert len(rate_rows) == 1
    assert rate_rows[0]["used_percent"] == 12.0


def test_codex_model_attribution_across_mid_session_change(cu, tmp_path):
    codex_home = tmp_path / "codex"
    path = codex_home / "sessions" / "2026" / "09" / "21" / "rollout-mid-change.jsonl"
    events = [
        {"type": "session_meta", "timestamp": "2026-09-21T10:00:00Z", "payload": {"id": "codex-sess-2", "type": "session_meta"}},
        {"type": "turn_context", "timestamp": "2026-09-21T10:00:01Z", "payload": {"type": "turn_context", "model": "gpt-6-sol"}},
        {"type": "event_msg", "timestamp": "2026-09-21T10:01:00Z", "payload": {
            "type": "token_count",
            "info": {"last_token_usage": {"input_tokens": 500, "cached_input_tokens": 0, "output_tokens": 100}},
        }},
        {"type": "turn_context", "timestamp": "2026-09-21T10:02:00Z", "payload": {"type": "turn_context", "model": "gpt-6-astra"}},
        {"type": "event_msg", "timestamp": "2026-09-21T10:03:00Z", "payload": {
            "type": "token_count",
            "info": {"last_token_usage": {"input_tokens": 700, "cached_input_tokens": 0, "output_tokens": 200}},
        }},
    ]
    _codex_rollout(path, "codex-sess-2", events)
    usage_rows, _ = cu.all_sessions_codex_rows(path)
    by_model = {r["model"]: r for r in usage_rows}
    assert by_model["gpt-6-sol"]["tokens"]["input"] == 500
    assert by_model["gpt-6-astra"]["tokens"]["input"] == 700


# ---------------------------------------------------------------------------
# The default dt-build mode's output is byte-for-byte unchanged (golden comparison
# against the pre-change collect-usage.py).
# ---------------------------------------------------------------------------

def _build_dt_build_fixture_tree(root: Path) -> tuple[Path, Path]:
    claude_home = root / "claude_home"
    codex_home = root / "codex_home"
    session_id = "chunk-session-1"
    _write_claude_session(claude_home / "projects", "proj-dtbuild", session_id, [
        {"type": "user", "timestamp": "2026-09-20T10:00:00Z",
         "message": {"content": "RUN_ID: run-golden chunk_id: chunk-1 bundle_sha256: deadbeef"}},
        _assistant_line("2026-09-20T10:05:00Z", "gm1", "claude-sonnet-5",
                         {"input_tokens": 1000, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 50, "output_tokens": 300}),
    ])
    sub_dir = claude_home / "projects" / "proj-dtbuild" / session_id / "subagents"
    sub_dir.mkdir(parents=True)
    (sub_dir / "sub1.jsonl").write_text("".join(json.dumps(l) + "\n" for l in [
        _assistant_line("2026-09-20T10:06:00Z", "gsub1", "claude-haiku-4-5",
                         {"input_tokens": 200, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 40}),
    ]), encoding="utf-8")
    return claude_home, codex_home


def _run_collect_usage(script: Path, out_dir: Path, cache_dir: Path, claude_home: Path, codex_home: Path) -> subprocess.CompletedProcess:
    env = {
        "CLAUDE_CONFIG_DIR": str(claude_home), "CODEX_HOME": str(codex_home),
        "DT_BUILD_USAGE_CACHE": str(cache_dir),
        "PATH": __import__("os").environ.get("PATH", ""),
        "SYSTEMROOT": __import__("os").environ.get("SYSTEMROOT", ""),
    }
    return subprocess.run(
        [sys.executable, str(script), "--out", str(out_dir), "--baseline", "2026-09-20", "--quiet"],
        capture_output=True, text=True, env=env, check=True,
    )


_GEN_LINE_RE = re.compile(r"Generated \d{4}-\d{2}-\d{2} \d{2}:\d{2}")


def test_default_dt_build_mode_output_unchanged_vs_baseline(tmp_path):
    claude_home, codex_home = _build_dt_build_fixture_tree(tmp_path / "fixture")

    baseline_out = tmp_path / "baseline_out"
    current_out = tmp_path / "current_out"
    baseline_cache = tmp_path / "baseline_cache"
    current_cache = tmp_path / "current_cache"

    _run_collect_usage(BASELINE_PATH, baseline_out, baseline_cache, claude_home, codex_home)
    _run_collect_usage(COLLECT_USAGE_PATH, current_out, current_cache, claude_home, codex_home)

    baseline_files = sorted(p.name for p in baseline_out.iterdir())
    current_files = sorted(p.name for p in current_out.iterdir())
    assert baseline_files == current_files

    for name in baseline_files:
        b = (baseline_out / name).read_text(encoding="utf-8")
        c = (current_out / name).read_text(encoding="utf-8")
        b = _GEN_LINE_RE.sub("Generated <ts>", b)
        c = _GEN_LINE_RE.sub("Generated <ts>", c)
        assert b == c, f"{name} differs between baseline and current default-mode output"


@pytest.mark.parametrize("exit_code", [0, 1])
def test_cost_report_refreshes_all_sessions_with_fake_sweep(tmp_path, exit_code):
    sweep = tmp_path / "fake_sweep.py"
    marker = tmp_path / "sweep_args.json"
    sweep.write_text(
        "import json, pathlib, sys\n"
        f"pathlib.Path({str(marker)!r}).write_text(json.dumps(sys.argv[1:]))\n"
        f"sys.exit({exit_code})\n",
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["DT_MODEL_ROUTER_STATE"] = str(tmp_path / "state")
    env["DT_MODEL_ROUTER_USAGE_SWEEP"] = str(sweep)
    # The Discord-delivery step this milestone adds must never reach a real transport.
    fake_transport = tmp_path / "fake-transport.ps1"
    fake_transport.write_text(
        "param($request)\nif ($request['kind'] -eq 'secret') { return 'fake-secret' }\n"
        "if ($request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '123' } } }\n"
        "if ($request['uri'] -like '*/users/@me/channels') { return [pscustomobject]@{ id = 'dm-channel' } }\n"
        "return [pscustomobject]@{ id = 'fake-message' }\n",
        encoding="utf-8",
    )
    env["DT_MODEL_ROUTER_ALERT_TRANSPORT"] = str(fake_transport)
    state = Path(env["DT_MODEL_ROUTER_STATE"])
    state.mkdir()
    (state / "usage-all-sessions.jsonl").write_text(json.dumps({
        "kind": "usage", "host": "codex", "session_id": "fixture", "model": "gpt-6-sol",
        "date_et": "2026-09-21", "tokens": {"input": 10, "cache_write": 0, "cache_read": 0, "output": 2},
    }) + "\n", encoding="utf-8")
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(REPO_ROOT / "scripts/model-router/cost-report.ps1"),
         "-StateDir", env["DT_MODEL_ROUTER_STATE"]],
        capture_output=True, text=True, env=env, timeout=30,
    )
    assert result.returncode == 0
    assert json.loads(marker.read_text(encoding="utf-8")) == ["--all-sessions", "--quiet"]
    assert ("usage sweep failed" in result.stdout) is bool(exit_code)
    assert (tmp_path / "state" / "cost-reports" / "latest.md").exists()
    assert (tmp_path / "state" / "cost-reports" / "discord-summary.json").exists()
    assert "weekly summary sent (discord)" in result.stdout

def test_python_state_writers_create_gitignore(tmp_path, cu):
    for module, sub in ((cr, "a"), (cu, "b")):
        state = module.ensure_state_gitignore(tmp_path / sub)
        assert (state / ".gitignore").read_text(encoding="utf-8") == "*\n"
    keep = tmp_path / "c"
    keep.mkdir()
    (keep / ".gitignore").write_text("custom\n", encoding="utf-8")
    cr.ensure_state_gitignore(keep)
    assert (keep / ".gitignore").read_text(encoding="utf-8") == "custom\n"


# ---------------------------------------------------------------------------
# Weekly Discord summary renderer (plain-language DM sent by cost-report.ps1)
# ---------------------------------------------------------------------------

def _row(host, model, date_et, **tokens):
    tok = {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0}
    tok.update(tokens)
    return {"kind": "usage", "host": host, "model": model, "session_id": f"s-{host}-{model}-{date_et}",
            "date_et": date_et, "calls": 1, "tokens": tok}


def test_previous_complete_iso_week_monday_and_midweek():
    # 2026-09-28 is a Monday (ISO week 40); the last complete week is 39 (Sep 21-27).
    assert cr.previous_complete_iso_week(date(2026, 9, 28)) == (2026, 39)
    # A mid-week day in the same ISO week resolves to the same prior complete week.
    assert cr.previous_complete_iso_week(date(2026, 10, 1)) == (2026, 39)


@pytest.mark.parametrize("scenario", ["zero_tokens", "zero_prices", "normal_prices"])
def test_summary_most_used_handles_zero_cost_rows(tmp_path, scenario):
    prices = json.loads(json.dumps(SYNTH_PRICES))
    if scenario == "zero_prices":
        for model in prices["models"].values():
            model["prices_usd_per_mtok"] = {key: 0 for key in model["prices_usd_per_mtok"]}
    tokens = 0 if scenario == "zero_tokens" else 1_000_000
    rows = [_row("claude", "claude-test-model", "2026-09-30", input=tokens),
            _row("codex", "gpt-test-model", "2026-09-30", input=tokens)]
    reports = cr.build_weekly_reports(rows, [], prices, date(2026, 10, 5))
    _, message = cr.render_discord_summary(reports, date(2026, 10, 5), tmp_path)
    expected = "50%" if scenario == "normal_prices" else "n/a"
    assert f"Test Model {expected}" in message
    assert f"gpt-test-model {expected}" in message
    assert "Most used:" in message
    if scenario != "normal_prices":
        assert all(model["share_pct"] is None for model in reports[0]["work_by_model"])


def test_format_week_range_same_and_crossing_month():
    assert cr.format_week_range(date(2026, 9, 21), date(2026, 9, 27)) == "Sep 21-27"
    assert cr.format_week_range(date(2026, 9, 28), date(2026, 10, 4)) == "Sep 28-Oct 4"


def test_friendly_model_name_map_and_generic_fallback():
    assert cr.friendly_model_name("gpt-6-sol") == "GPT-6 Sol"
    assert cr.friendly_model_name("gpt-6-luna") == "GPT-6 Luna"
    assert cr.friendly_model_name("gpt-image-2") == "gpt-image-2"
    assert cr.friendly_model_name("claude-opus-5-5") == "Opus 5.5"
    assert cr.friendly_model_name("claude-haiku-4-5-20251001") == "Haiku 4.5"
    # Unmapped claude-* id: strip vendor prefix, strip trailing date, "name-N-M" -> "Name N.M".
    assert cr.friendly_model_name("claude-sonnet-5-20260101") == "Sonnet 5"
    assert cr.friendly_model_name("claude-mythos-5-1") == "Mythos 5.1"
    # Unmapped, non-claude id: raw fallback, never guessed.
    assert cr.friendly_model_name("gpt-9-nova") == "gpt-9-nova"
    assert cr.friendly_model_name(None) == ""


def _synth_report(week=(2026, 39), claude_sub=46.0, claude_api=0.0, codex_sub=46.0, codex_api=0.0,
                   blocked_minutes=0.0, work_by_model=None, frontier_ids=None, frontier_cost=0.0,
                   include_codex=True, include_claude=True):
    vendors = {}
    if include_claude:
        vendors["claude"] = cr.VendorWeek(host="claude", label="Claude", subscription_usd=claude_sub,
                                           api_equivalent_usd=claude_api, blocked_minutes=None)
    if include_codex:
        vendors["codex"] = cr.VendorWeek(host="codex", label="Codex", subscription_usd=codex_sub,
                                          api_equivalent_usd=codex_api, blocked_minutes=blocked_minutes)
    return {
        "iso_year": week[0], "iso_week": week[1], "label": cr.week_label(*week),
        "vendors": vendors, "work_by_model": work_by_model or [],
        "frontier": {"api_equivalent_usd": frontier_cost, "sessions": 0, "model_ids": frontier_ids or []},
    }


@pytest.mark.parametrize("present", [True, False])
def test_claude_latest_usage_rendered_in_markdown_html_and_discord(tmp_path, present):
    reading = {
        "used_percent": 67.0, "session_percent": 8.0,
        "observed_at_utc": "2026-09-30T21:00:00+00:00",
        "resets_at_utc": "2026-10-03T18:00:00+00:00", "source": "oauth-usage",
        "session_resets_at_utc": None,
    }
    if present:
        (tmp_path / "claude-usage.json").write_text(json.dumps(reading), encoding="utf-8")
    loaded = cr.load_claude_usage(tmp_path)
    assert loaded == (reading if present else None)
    report = _synth_report()
    report["claude_usage"] = loaded
    expected = ("Claude weekly usage: 67% of the weekly limit at Sep 30, 5:00 PM ET, "
                "resets Oct 3, 2:00 PM ET; 5-hour window 8%") if present else "no Claude usage reading yet"
    outputs = [cr.render_markdown(report), cr.render_html(report),
               cr.render_discord_summary([report], date(2026, 9, 28), tmp_path)[1]]
    for output in outputs:
        assert expected in output
        assert "Claude blocked-minutes are not computed" in output
        assert "only the latest reading is kept, not a history" in output
        assert "no Claude account-level quota field" not in output


def test_claude_usage_cache_corrupt_or_invalid_is_unknown(tmp_path):
    cache = tmp_path / "claude-usage.json"
    for text in ("{broken", "[]", '{}', '{"used_percent": "invalid"}'):
        cache.write_text(text, encoding="utf-8")
        assert cr.load_claude_usage(tmp_path) is None


def test_headline_math_subscription_ahead_and_api_cheaper():
    report = _synth_report(claude_api=100.0, claude_sub=46.0, codex_api=48.0, codex_sub=46.0)
    assert cr.render_headline(report) == "Your plans covered $148 of work for $92 in subscription cost."
    cheaper = _synth_report(claude_api=10.0, claude_sub=46.0, codex_api=10.0, codex_sub=46.0)
    assert cr.render_headline(cheaper) == (
        "Your plans covered $20 of work for $92 in subscription cost "
        "(API pricing would have been cheaper this week)."
    )
    large = _synth_report(claude_api=2019.4, claude_sub=46.0, codex_api=1546.8, codex_sub=46.0)
    assert cr.render_headline(large) == "Your plans covered $3,566 of work for $92 in subscription cost."
    assert cr.render_vendor_lines(large["vendors"])[0] == "- Claude: $2,019 of work (at API prices) on a $46/wk plan"


def test_vendor_lines_omit_absent_vendor():
    report = _synth_report(claude_api=100.0, include_codex=False)
    lines = cr.render_vendor_lines(report["vendors"])
    assert lines == ["- Claude: $100 of work (at API prices) on a $46/wk plan"]


def test_top3_ordering_and_friendly_names_skips_unpriced():
    work = [
        {"model": "gpt-6-sol", "api_equivalent_usd": 41.0, "share_pct": 41.0},
        {"model": "claude-opus-5-5", "api_equivalent_usd": 38.0, "share_pct": 38.0},
        {"model": "gpt-6-luna", "api_equivalent_usd": 12.0, "share_pct": 12.0},
        {"model": "claude-sonnet-5", "api_equivalent_usd": 9.0, "share_pct": 9.0},
        {"model": "unset", "api_equivalent_usd": None, "share_pct": None},
    ]
    top = cr.top_models(work)
    assert [m["model"] for m in top] == ["gpt-6-sol", "claude-opus-5-5", "gpt-6-luna"]
    most_used = " - ".join(f"{cr.friendly_model_name(m['model'])} {round(m['share_pct'])}%" for m in top)
    assert most_used == "GPT-6 Sol 41% - Opus 5.5 38% - GPT-6 Luna 12%"


def test_frontier_line_used_and_not_used():
    frontier_models = {"claude_patterns": ["claude-fable-*"], "codex_models": ["gpt-6-astra"]}
    not_used = _synth_report()
    assert cr.render_frontier_line(not_used, frontier_models) == "Frontier models (Fable/Astra): not used"
    used = _synth_report(frontier_ids=["gpt-6-astra"], frontier_cost=31.0)
    assert cr.render_frontier_line(used, frontier_models) == (
        "Frontier models (Fable/Astra): used - GPT-6 Astra, $31 of work at API prices"
    )


def test_codex_limit_line_none_zero_and_positive():
    assert cr.render_codex_limit_line(_synth_report(blocked_minutes=None)["vendors"]) == "Codex usage limit: no data"
    assert cr.render_codex_limit_line(_synth_report(blocked_minutes=0.0)["vendors"]) == "Codex usage limit: never hit"
    assert cr.render_codex_limit_line(_synth_report(blocked_minutes=125.0)["vendors"]) == (
        "Codex usage limit: maxed out for about 2h 5m"
    )
    assert cr.render_codex_limit_line(_synth_report(blocked_minutes=40.0)["vendors"]) == (
        "Codex usage limit: maxed out for about 40m"
    )
    assert cr.render_codex_limit_line(_synth_report(include_codex=False)["vendors"]) is None


# --- Needs-you: pending roster proposal, drift marks, corruption tolerance ---

def _write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(obj, dict) and "jobs" in obj:
        obj = json.loads(json.dumps(obj))
        defaults = json.loads((REPO_ROOT / "references/model-router/default-roster.json").read_text(encoding="utf-8"))
        for job, entry in obj["jobs"].items():
            for slot in ("first", "backup"):
                entry[f"{slot}_effort"] = defaults["jobs"][job][f"{slot}_effort"]
    path.write_text(json.dumps(obj), encoding="utf-8")


def test_needs_you_pending_proposal_when_never_approved(tmp_path):
    state = tmp_path / "state"
    proposal_path = state / "roster-proposals" / "seed.json"
    _write_json(proposal_path, {"jobs": {"fast": {"first": "gpt-6-luna", "backup": "claude-haiku-4-5-20251001"}}})
    _write_json(state / "roster-proposals" / "latest.json", {"proposal": str(proposal_path)})
    lines = cr.compute_needs_you_lines(state)
    assert len(lines) == 2
    assert lines[0] == "the bench golden review is waiting for your OK; comparisons remain in shadow mode."
    assert "a proposed change to the model list is waiting for your OK" in lines[1]
    assert "approve-roster.ps1" in lines[1]
    assert "-Show" in lines[1]
    assert "-Roster" not in lines[1]


def test_needs_you_nothing_when_proposal_fully_approved(tmp_path):
    state = tmp_path / "state"
    jobs = {
        "fast": {"first": "gpt-6-luna", "backup": "claude-haiku-4-5-20251001"},
        "coder": {"first": "gpt-6-sol", "backup": "claude-opus-5-5"},
        "deep-thinker": {"first": "claude-opus-5-5", "backup": "gpt-6-sol"},
        "writer": {"first": "claude-opus-5-5", "backup": "gpt-6-sol"},
        "illustrator": {"first": "gpt-image-2", "backup": None},
    }
    proposal_path = state / "roster-proposals" / "seed.json"
    _write_json(proposal_path, {"jobs": jobs, "approved": False})
    _write_json(state / "roster-proposals" / "latest.json", {"proposal": str(proposal_path)})
    _write_json(state / "roster.json", {"approved": True, "jobs": jobs})
    assert cr.compute_needs_you_lines(state) == ["the bench golden review is waiting for your OK; comparisons remain in shadow mode."]


def test_needs_you_pending_when_partial_jobs_approval_leaves_a_mismatch(tmp_path):
    state = tmp_path / "state"
    proposed_jobs = {
        "fast": {"first": "gpt-6-luna", "backup": "claude-sonnet-5"},
        "coder": {"first": "gpt-6-sol", "backup": "claude-opus-5-5"},
    }
    approved_jobs = {  # only "coder" was approved into state; "fast" still differs
        "fast": {"first": "gpt-6-luna", "backup": "claude-haiku-4-5-20251001"},
        "coder": {"first": "gpt-6-sol", "backup": "claude-opus-5-5"},
    }
    proposal_path = state / "roster-proposals" / "seed.json"
    _write_json(proposal_path, {"jobs": proposed_jobs})
    _write_json(state / "roster-proposals" / "latest.json", {"proposal": str(proposal_path)})
    _write_json(state / "roster.json", {"approved": True, "jobs": approved_jobs})
    lines = cr.compute_needs_you_lines(state)
    assert len(lines) == 2
    assert lines[0] == "the bench golden review is waiting for your OK; comparisons remain in shadow mode."
    assert "model list is waiting" in lines[1]


def test_needs_you_active_drift_mark_names_job_and_backup(tmp_path):
    state = tmp_path / "state"
    _write_json(state / "drift-marks.json", [{"model": "gpt-6-sol", "job": "coder", "marked_at": "2026-09-28T00:00:00Z"}])
    _write_json(state / "roster.json", {"approved": True, "jobs": {
        "coder": {"first": "gpt-6-sol", "backup": "claude-opus-5-5"},
    }})
    lines = cr.compute_needs_you_lines(state)
    assert len(lines) == 2
    assert lines[0] == "the bench golden review is waiting for your OK; comparisons remain in shadow mode."
    assert "the coder job is on its backup (Opus 5.5) because GPT-6 Sol has been underperforming" in lines[1]
    assert "-DeclineDrift -Job coder" in lines[1]


def test_needs_you_declined_drift_mark_is_excluded(tmp_path):
    state = tmp_path / "state"
    _write_json(state / "drift-marks.json", [{"model": "gpt-6-sol", "job": "coder", "marked_at": "2026-09-28T00:00:00Z"}])
    _write_json(state / "drift-declines.json", [{"model": "gpt-6-sol", "job": "coder", "declined_at": "2026-09-28T00:00:00Z"}])
    _write_json(state / "roster.json", {"approved": True, "jobs": {
        "coder": {"first": "gpt-6-sol", "backup": "claude-opus-5-5"},
    }})
    assert cr.compute_needs_you_lines(state) == ["the bench golden review is waiting for your OK; comparisons remain in shadow mode."]


def test_needs_you_tolerates_corrupt_state_files(tmp_path):
    state = tmp_path / "state"
    state.mkdir(parents=True)
    (state / "roster-proposals").mkdir()
    (state / "roster-proposals" / "latest.json").write_text("{not json", encoding="utf-8")
    (state / "drift-marks.json").write_text("[{broken", encoding="utf-8")
    (state / "roster.json").write_text("not even json", encoding="utf-8")
    assert cr.compute_needs_you_lines(state) == ["the bench golden review is waiting for your OK; comparisons remain in shadow mode."]


def test_needs_you_multiple_findings_produce_a_bullet_each(tmp_path):
    state = tmp_path / "state"
    proposal_path = state / "roster-proposals" / "seed.json"
    _write_json(proposal_path, {"jobs": {"fast": {"first": "claude-sonnet-5", "backup": "gpt-6-luna"}}})
    _write_json(state / "roster-proposals" / "latest.json", {"proposal": str(proposal_path)})
    _write_json(state / "drift-marks.json", [{"model": "gpt-6-sol", "job": "coder", "marked_at": "2026-09-28T00:00:00Z"}])
    _write_json(state / "roster.json", {"approved": True, "jobs": {
        "fast": {"first": "gpt-6-luna", "backup": "claude-haiku-4-5-20251001"},
        "coder": {"first": "gpt-6-sol", "backup": "claude-opus-5-5"},
    }})
    text = cr.render_needs_you(cr.compute_needs_you_lines(state))
    assert text.startswith("Needs you:\n- ")
    assert text.count("\n- ") == 3


# --- End-to-end render_discord_summary: no-data week, complete actions, JSON file ---

def test_render_discord_summary_no_data_week_still_includes_needs_you(tmp_path):
    state = tmp_path / "state"
    proposal_path = state / "roster-proposals" / "seed.json"
    _write_json(proposal_path, {"jobs": {"fast": {"first": "gpt-6-luna", "backup": "claude-haiku-4-5-20251001"}}})
    _write_json(state / "roster-proposals" / "latest.json", {"proposal": str(proposal_path)})
    label, message = cr.render_discord_summary([], date(2026, 9, 28), state)
    assert label == "2026-W39"
    assert message.splitlines()[0] == "**Model router - week of Sep 21-27**"
    assert "No model usage was recorded last week." in message
    assert "Needs you:" in message and "waiting for your OK" in message
    assert "Full report:" not in message


def test_render_discord_summary_preserves_all_roster_actions(tmp_path):
    state = tmp_path / "state"
    marks = [{"model": "gpt-6-sol", "job": job, "marked_at": "2026-09-28T00:00:00Z"} for job in
              ("fast", "coder", "deep-thinker", "writer")]
    _write_json(state / "drift-marks.json", marks)
    roster_jobs = {job: {"first": "gpt-6-sol", "backup": "claude-opus-5-5"} for job in
                   ("fast", "coder", "deep-thinker", "writer")}
    _write_json(state / "roster.json", {"approved": True, "jobs": roster_jobs})
    padding_proposal = state / "roster-proposals" / "seed.json"
    _write_json(padding_proposal, {"jobs": {"illustrator": {"first": "gpt-image-2", "backup": None}}})
    _write_json(state / "roster-proposals" / "latest.json", {"proposal": str(padding_proposal)})
    label, message = cr.render_discord_summary([], date(2026, 9, 28), state)
    assert message.splitlines()[0] == "**Model router - week of Sep 21-27**"
    for action in cr.compute_needs_you_lines(state):
        assert action in message


def test_cost_report_main_writes_discord_summary_json(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    (state / "claude-usage.json").write_text(json.dumps({
        "used_percent": 67, "session_percent": 8,
        "observed_at_utc": "2026-09-30T21:00:00Z", "resets_at_utc": "2026-10-03T18:00:00Z",
    }), encoding="utf-8")
    usage_path = state / "usage-all-sessions.jsonl"
    monday, _ = cr.week_bounds_et(2026, 39)
    usage_path.write_text(
        json.dumps(_row("claude", "claude-opus-5-5", monday.isoformat(), input=1_000_000, output=1_000_000)) + "\n",
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["DT_MODEL_ROUTER_STATE"] = str(state)
    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts/model-router/cost_report.py"), "--state-dir", str(state)],
        capture_output=True, text=True, env=env, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    summary_path = state / "cost-reports" / "discord-summary.json"
    assert summary_path.is_file()
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    assert summary["key"].startswith("weekly-report:")
    assert isinstance(summary["message"], str) and summary["message"]
    assert "Claude weekly usage: 67%" in summary["message"]
    assert "resets Oct 3, 2:00 PM ET" in (state / "cost-reports/latest.md").read_text(encoding="utf-8")

# M11: routing rows are counts, never priced usage.
def _routing(day="2026-09-30", station="Skill Creation", session="routing-test", routed=2, unrouted=1):
    return {"kind": "routing", "host": "claude", "session_id": session, "project": "fixture",
            "workstation": station, "date_et": day, "delegations": routed + unrouted,
            "routed": routed, "unrouted": unrouted, "by_category": {"planning": routed},
            "by_job": {"deep-thinker": routed}}


def test_routing_week_split_rollup_and_cost_isolation(tmp_path):
    usage = {"kind": "usage", "host": "claude", "session_id": "priced", "model": "claude-test-model",
             "date_et": "2026-09-30", "calls": 1, "tokens": {"input": 1000000}}
    rows = [_routing(), _routing("2026-10-01"), _routing(station="workspace root", unrouted=4),
            _routing(station="other", unrouted=8), _routing("2026-10-05")]
    ledger = tmp_path / "usage.jsonl"
    ledger.write_text("\n".join(json.dumps(r) for r in [usage, *rows]), encoding="utf-8")
    usage_rows, rates = cr.load_usage_all_sessions(ledger)
    routing = [r for r in cr.load_jsonl(ledger) if r["kind"] == "routing"]
    reports = cr.build_weekly_reports(usage_rows, rates, SYNTH_PRICES, date(2026, 10, 12), routing_rows=routing)
    assert len(reports) == 2
    report = reports[0]
    assert report["vendors"]["claude"].api_equivalent_usd == 10
    stations = {s["workstation"]: s for s in report["routing"]["workstations"]}
    assert stations["Skill Creation"]["sessions"] == 1
    assert stations["Skill Creation"]["delegations"] == 6
    assert set(stations) == {"Skill Creation", "workspace root", "other"}
    assert report["routing"]["distribution"] == [
        {"axis": "Category", "name": "planning", "delegations": 8},
        {"axis": "Job", "name": "deep-thinker", "delegations": 8}]
    for rendered in [cr.render_markdown(report), cr.render_html(report)]:
        assert "Routing compliance by workstation" in rendered
        assert "Delegations by category and job" in rendered
        assert "workspace root" in rendered and "other" in rendered
    assert cr.render_html(report).count("<table>") == 2
    _, message = cr.render_discord_summary(reports, date(2026, 10, 5), tmp_path)
    assert "rule started Wed Sep 30" in message
    assert "36% of 22 delegations" in message
    assert "other (8)" in message
    assert "rule started" not in cr.render_routing_line(reports[1])


def test_routing_unknown_zero_and_html_escape(tmp_path):
    report = cr.build_weekly_reports([], [], SYNTH_PRICES, date(2026, 10, 5),
                                    routing_rows=[_routing(station="<fixture>", routed=0, unrouted=0)])[0]
    assert "0 delegations" in cr.render_routing_line(report)
    assert "&lt;fixture&gt;" in cr.render_html(report)
    report["routing"] = cr.summarize_routing([])
    assert "no routing data" in cr.render_routing_line(report)


def _failure(state, category="planning", stamp="20260930T011400000", extra=""):
    path = state / "research-failures" / f"{category}@{stamp}-pass-fixture.txt"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("error: secret raw invocation\n" + extra, encoding="utf-8")
    return path


def test_research_episode_queued_then_stopped_and_recovered(tmp_path):
    _failure(tmp_path)
    _failure(tmp_path, stamp="20261001T011400000")
    _write_json(tmp_path / "research-queue.json", [{"categories": ["planning"]}])
    lines, needs = cr.research_episodes(tmp_path)
    assert len(lines) == 1 and not needs
    assert "Wed 1:14 AM ET" in lines[0] and "next overnight run" in lines[0]
    assert "secret raw invocation" not in lines[0]
    item = {"model": "model's-name", "trigger": "refresh", "categories": ["planning"], "reason": "rerun"}
    _failure(tmp_path, extra="stopped_item: " + json.dumps(item))
    lines, needs = cr.research_episodes(tmp_path)
    assert "next overnight run" not in lines[0] and "Needs you" in lines[0]
    assert "Add-RouterResearchQueueItem" in needs[0] and "'model''s-name'" in needs[0]
    _write_json(tmp_path / "readings" / "planning.json",
                {"researched_at": "2026-10-01T06:00:00Z", "readings": [{"results": [{"score": 1}]}]})
    assert cr.research_episodes(tmp_path) == ([], [])
    # A new failure after recovery starts a new episode.
    _failure(tmp_path, stamp="20261002T011400000")
    assert "Fri 1:14 AM ET" in cr.research_episodes(tmp_path)[0][0]


def test_research_legacy_recovery_requires_committed_success_and_results(tmp_path):
    _failure(tmp_path)
    _write_json(tmp_path / "readings" / "planning.json", {"readings": [{"results": [{"score": 1}]}]})
    path = tmp_path / "readings" / "passes.jsonl"
    record = {"categories": ["planning"], "failed_categories": [], "completed_at": "2026-10-01T06:00:00Z"}
    for flag in ("interrupted", "deferred"):
        path.write_text(json.dumps({**record, flag: True}), encoding="utf-8")
        assert cr.research_episodes(tmp_path)[0]
    path.write_text(json.dumps(record), encoding="utf-8")
    assert not cr.research_episodes(tmp_path)[0]
    _write_json(tmp_path / "readings" / "planning.json", {"readings": []})
    assert cr.research_episodes(tmp_path)[0]


def test_unqueued_and_manual_unexplained_research(tmp_path):
    _failure(tmp_path)
    lines, needs = cr.research_episodes(tmp_path)
    assert "next overnight run" not in lines[0] and not needs
    path = tmp_path / "readings" / "passes.jsonl"
    path.parent.mkdir()
    path.write_text(json.dumps({"pass_id": "pass-fixture", "categories": ["planning"],
                               "interrupted": True, "diagnosis": "unexplained"}), encoding="utf-8")
    lines, needs = cr.research_episodes(tmp_path)
    assert "Needs you" in lines[0] and "Inspect" in needs[0]


def test_reenqueued_research_supersedes_historical_unexplained_stop(tmp_path):
    item = {"model": "gpt-test-model", "trigger": "refresh", "categories": ["planning"], "reason": "rerun"}
    failure = _failure(tmp_path, extra="stopped_item: " + json.dumps(item))
    passes = tmp_path / "readings" / "passes.jsonl"
    passes.parent.mkdir()
    passes.write_text(json.dumps({"pass_id": "pass-fixture", "categories": ["planning"],
                                 "interrupted": True, "diagnosis": "unexplained"}), encoding="utf-8")
    _write_json(tmp_path / "research-queue.json", [])
    lines, needs = cr.research_episodes(tmp_path)
    assert "Needs you" in lines[0] and "next overnight run" not in lines[0]
    assert "Add-RouterResearchQueueItem" in needs[0]

    # Mirror explicit re-enqueue: the queue gains the item and its stopped marker is removed.
    _write_json(tmp_path / "research-queue.json", [item])
    failure.write_text("error: fixture\n", encoding="utf-8")
    lines, needs = cr.research_episodes(tmp_path)
    assert "next overnight run" in lines[0] and "Needs you" not in lines[0]
    assert needs == []


@pytest.mark.parametrize("with_usage", [True, False])
def test_summary_preserves_full_report_when_actions_exceed_1500_chars(tmp_path, with_usage):
    events = [{"event": "delivered", "key": f"vendor-error:codex:piece-{i}"} for i in range(7)]
    (tmp_path / "alert-log.jsonl").write_text("\n".join(json.dumps(e) for e in events), encoding="utf-8")
    _failure(tmp_path)
    _write_json(tmp_path / "research-queue.json", [{"categories": ["planning"]}])
    assert len(cr.render_needs_you(cr.vendor_error_needs(tmp_path))) > 1500
    reports = [dict(_synth_report(week=(2026, 40)), routing=cr.summarize_routing([_routing()]))] if with_usage else []
    _, message = cr.render_discord_summary(reports, date(2026, 10, 5), tmp_path)
    assert message.splitlines()[0] == "**Model router - week of Sep 28-Oct 4**"
    if with_usage:
        assert cr.render_routing_line(reports[0]) in message
        assert cr.render_headline(reports[0]) in message
        assert f"Full report: `{tmp_path / 'cost-reports' / 'weekly-2026-W40.html'}`" in message
    else:
        assert "No model usage was recorded last week." in message
    for line in cr.research_episodes(tmp_path)[0]:
        assert line in message
    assert cr.render_needs_you(cr.vendor_error_needs(tmp_path)) in message


def test_vendor_errors_every_delivered_unacknowledged_key_and_complete_commands(tmp_path):
    events = [{"event": "delivered", "key": f"vendor-error:codex:piece-{i}"} for i in range(5)]
    events += [events[0], {"event": "acknowledged", "key": "vendor-error:codex:piece-0"},
               {"event": "delivery_failed", "key": "vendor-error:claude:unsent"},
               {"event": "delivered", "key": "research-failure:planning:2026-09-30"}]
    (tmp_path / "alert-log.jsonl").write_text("\n".join(json.dumps(e) for e in events) + "\ninvalid", encoding="utf-8")
    lines = cr.vendor_error_needs(tmp_path)
    assert len(lines) == 4
    _, message = cr.render_discord_summary([], date(2026, 10, 5), tmp_path)
    for i in range(1, 5):
        assert f"-Acknowledge 'vendor-error:codex:piece-{i}'`" in message
    assert "piece-0" not in message and "unsent" not in message


def test_summary_research_with_no_usage_and_missing_routing_with_sessions(tmp_path):
    _failure(tmp_path)
    _, message = cr.render_discord_summary([], date(2026, 10, 5), tmp_path)
    assert "Research: the planning check" in message
    usage = {"host": "claude", "session_id": "fixture", "model": "claude-test-model",
             "date_et": "2026-09-30", "calls": 1, "tokens": {"input": 1000000}}
    reports = cr.build_weekly_reports([usage], [], SYNTH_PRICES, date(2026, 10, 5))
    _, message = cr.render_discord_summary(reports, date(2026, 10, 5), tmp_path)
    assert "Routing rule (Claude sessions) (rule started Wed Sep 30): no routing data" in message
