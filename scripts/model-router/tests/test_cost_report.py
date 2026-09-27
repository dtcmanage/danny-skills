"""Tests for the M07 API-equivalent cost report: cost_report.py plus the
--all-sessions extension to skills/dt-build/scripts/collect-usage.py.

pytest, fixtures only. No network, no model calls, DT_MODEL_ROUTER_STATE always points
at a pytest tmp_path.
"""
from __future__ import annotations

import importlib.util
import json
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
            "prices_usd_per_mtok": {"input": 10, "cached_input": 1, "output": 50},
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


def test_openai_pricing_math_folds_cache_write_into_input():
    row = {"host": "codex", "model": "gpt-test-model",
           "tokens": {"input": 500_000, "cache_write": 500_000, "cache_read": 1_000_000, "output": 1_000_000}}
    cost, _ = cr.price_usage_row(row, SYNTH_PRICES)
    # (input + cache_write) at input rate, cache_read at cached_input rate, output at output rate
    assert cost == pytest.approx((1_000_000 * 10 + 1_000_000 * 1 + 1_000_000 * 50) / 1_000_000)


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
