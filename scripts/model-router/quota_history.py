"""Durable vendor observations; stdlib only. Counters never establish reset cause."""
import argparse
import csv
import hashlib
import json
import math
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


def utc(value: object) -> str:
    if isinstance(value, (int, float)):
        date = datetime.fromtimestamp(value, timezone.utc)
    else:
        date = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if date.tzinfo is None:
        raise ValueError("timestamp needs timezone")
    return date.astimezone(timezone.utc).isoformat(timespec="microseconds")


def now_utc() -> str:
    return utc(datetime.now(timezone.utc).isoformat())


def normalize(payload: dict) -> list[dict]:
    """Allowlist vendor fields; never persist the raw envelope or credential locator."""
    vendor = payload["vendor"]
    if vendor not in ("codex", "claude"):
        raise ValueError("unknown vendor")
    observed = utc(payload["observed_at_utc"])
    collected = utc(payload.get("collected_at_utc") or now_utc())
    provenance = payload.get("provenance", "fresh")
    if provenance not in ("fresh", "cache", "backfill"):
        raise ValueError("unknown provenance")
    rows = []

    def add(limit: str, window: str, data: dict | None, used_key: str,
            reset_key: str, duration_key: str, scope: object = None) -> None:
        data = data or {}
        used, reset = data.get(used_key), data.get(reset_key)
        status = "valid"
        try:
            if used is not None:
                used = float(used)
                if not math.isfinite(used) or used < 0 or used > 100:
                    raise ValueError("invalid percentage")
            reset = utc(reset) if reset is not None else None
        except (ValueError, TypeError, OverflowError):
            used, reset, status = None, None, "invalid"
        metadata = {key: data.get(key) for key in (used_key, reset_key, duration_key)}
        rows.append(dict(vendor=vendor, owner_profile=payload.get("owner_profile") or "danny-local-owner",
                         limit_id=str(limit), window_id=str(window), reported_scope=scope,
                         observed_at_utc=observed, collected_at_utc=collected,
                         used_percent=used, remaining_percent=None if used is None else 100 - used,
                         resets_at_utc=reset, source=payload["source"], provenance=provenance,
                         metadata=metadata, status=status))

    raw = payload.get("data") or {}
    if vendor == "claude":
        # The endpoint can expose seven_day_sonnet, seven_day_opus and feature windows.
        # Keep each reported key; never expand shared seven_day into model quotas.
        for key, value in raw.items():
            if key == "source":
                continue
            if value is None or isinstance(value, dict) and ("utilization" in value or "resets_at" in value):
                add(key, key, value, "utilization", "resets_at", "window_duration_minutes", key)
    elif payload["source"] == "codex-bench-weekly":
        # The legacy bench contract does not expose a limit ID. Do not pretend its
        # weekly value belongs to a known account/feature pool.
        add("unreported", "minutes:10080", raw, "used_percent", "resets_at_utc", "window_minutes")
    else:
        pools = raw.get("rateLimitsByLimitId") or {}
        if not isinstance(pools, dict):
            pools = {}
        pools = dict(pools)
        if raw.get("rateLimits"):
            legacy = raw["rateLimits"]
            pools.setdefault(legacy.get("limitId") or legacy.get("limit_id") or "codex", legacy)
        for limit, pool in pools.items():
            if not isinstance(pool, dict):
                continue
            for key in ("primary", "secondary"):
                value = pool.get(key)
                duration = (value or {}).get("windowDurationMins", (value or {}).get("window_minutes"))
                window = f"minutes:{duration}" if duration is not None else key
                snake = "used_percent" in (value or {})
                add(limit, window, value, "used_percent" if snake else "usedPercent",
                    "resets_at" if snake else "resetsAt", "window_minutes" if snake else "windowDurationMins",
                    pool.get("limitName") or pool.get("limit_name"))
                rows[-1]["metadata"].update({k: pool[k] for k in
                    ("normalModelSlug", "planType", "rateLimitReachedType", "spendControlReached") if k in pool})
            individual = pool.get("individualLimit")
            if isinstance(individual, dict):
                remaining = individual.get("remainingPercent")
                used = 100 - remaining if isinstance(remaining, (int, float)) else None
                add(limit, "individualLimit", dict(individual, usedPercent=used), "usedPercent", "resetsAt", "windowDurationMins",
                    pool.get("limitName"))
                rows[-1]["metadata"].update({k: individual[k] for k in ("remainingPercent", "limit", "used") if k in individual})
    return rows


def classify(old: dict, new: dict) -> dict | None:
    """Describe evidence across an interval; a scheduled deadline makes drops ambiguous."""
    if any(row.get("used_percent") is None or row.get("resets_at_utc") is None for row in (old, new)):
        return None
    drop = new["used_percent"] < old["used_percent"]
    moved = new["resets_at_utc"] != old["resets_at_utc"]
    crossed = old["observed_at_utc"] < old["resets_at_utc"] <= new["observed_at_utc"]
    if not drop and not moved:
        return None
    if not drop:
        kind, reason, confidence = "schedule_change", "deadline moved without observed usage restoration", "observed"
    elif crossed:
        kind, reason, confidence = "scheduled_consistent", "interval spans expected deadline; extra resets cannot be resolved", "ambiguous"
    elif drop:
        kind = "unexpected_drop_deadline_change" if moved else "unexpected_drop"
        reason, confidence = "possible extra reset or counter correction; cause unknown", "possible"
    return dict(kind=kind, reason=reason, confidence=confidence, cause="unknown",
                old_used_percent=old["used_percent"], new_used_percent=new["used_percent"],
                old_reset_at_utc=old["resets_at_utc"], new_reset_at_utc=new["resets_at_utc"],
                interval_start_utc=old["observed_at_utc"], interval_end_utc=new["observed_at_utc"])


SCHEMA = """
CREATE TABLE IF NOT EXISTS {db}.facts (
 id TEXT PRIMARY KEY, observed TEXT NOT NULL, kind TEXT NOT NULL, body TEXT NOT NULL);
"""


def ingest(state: Path, payload: dict) -> dict:
    rows = normalize(payload)
    state.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(state / "quota-history.sqlite", timeout=30) as db:
        # DELETE journal + attached DB gives one atomic commit for archive movement as well.
        db.execute("ATTACH DATABASE ? AS archive", (str(state / "quota-history-archive.sqlite"),))
        for name in ("main", "archive"):
            db.executescript(SCHEMA.format(db=name))
        db.execute("CREATE TABLE IF NOT EXISTS baseline (key TEXT PRIMARY KEY, body TEXT NOT NULL)")
        db.execute("BEGIN IMMEDIATE")
        counts = {"accepted": 0, "duplicate": 0, "stale": 0, "invalid": 0, "events": 0}
        for row in rows:
            key = json.dumps([row[k] for k in ("vendor", "owner_profile", "limit_id", "window_id")])
            # A repeated source timestamp/value is the same observation even via another cache path.
            identity = {k: row[k] for k in ("observed_at_utc", "used_percent", "resets_at_utc", "status")}
            fid = hashlib.sha256((key + json.dumps(identity, sort_keys=True)).encode()).hexdigest()
            if db.execute("SELECT 1 FROM main.facts WHERE id=? UNION ALL SELECT 1 FROM archive.facts WHERE id=?", (fid, fid)).fetchone():
                counts["duplicate"] += 1
                continue
            prior = db.execute("SELECT body FROM baseline WHERE key=?", (key,)).fetchone()
            old = json.loads(prior[0]) if prior else None
            if row["status"] == "invalid":
                counts["invalid"] += 1
            elif row["observed_at_utc"] > row["collected_at_utc"]:
                row["status"] = "invalid_future"
                counts["invalid"] += 1
            elif row["resets_at_utc"] is not None and row["resets_at_utc"] <= row["observed_at_utc"]:
                row["status"] = "expired_source"
                counts["invalid"] += 1
            elif old and row["observed_at_utc"] <= old["observed_at_utc"]:
                row["status"] = "stale_or_correction"
                counts["stale"] += 1
            else:
                event = classify(old, row) if old else None
                if event:
                    event.update({k: row[k] for k in ("vendor", "owner_profile", "limit_id", "window_id", "provenance", "source")})
                    db.execute("INSERT INTO facts VALUES (?,?,?,?)", ("event:" + fid, row["observed_at_utc"], "event", json.dumps(event)))
                    counts["events"] += 1
                # Missing windows are facts, but cannot erase the last comparable baseline.
                if row["used_percent"] is not None and row["resets_at_utc"] is not None:
                    db.execute("INSERT OR REPLACE INTO baseline VALUES (?,?)", (key, json.dumps(row)))
                counts["accepted"] += 1
            db.execute("INSERT INTO facts VALUES (?,?,?,?)", (fid, row["observed_at_utc"], "observation", json.dumps(row)))
        cutoff = utc((datetime.fromisoformat(utc(payload.get("collected_at_utc") or now_utc())) - timedelta(days=90)).isoformat())
        db.execute("INSERT OR IGNORE INTO archive.facts SELECT * FROM main.facts WHERE observed < ?", (cutoff,))
        db.execute("DELETE FROM main.facts WHERE observed < ?", (cutoff,))
    return dict(status="recorded" if rows else "no_windows", **counts)


def read_history(state: Path, archives: bool = False, kind: str = "observation") -> list[dict]:
    rows = []
    for name in ("quota-history.sqlite", "quota-history-archive.sqlite") if archives else ("quota-history.sqlite",):
        path = state / name
        if path.exists():
            with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
                rows.extend((observed, fid, json.loads(body)) for fid, observed, body in db.execute(
                    "SELECT id, observed, body FROM facts WHERE kind=?", (kind,)))
    return [row[2] for row in sorted(rows)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--ingest", action="store_true", help="sanitized vendor envelope from stdin; owner-host caller only")
    parser.add_argument("--include-archives", action="store_true")
    parser.add_argument("--events", action="store_true")
    parser.add_argument("--format", choices=("json", "csv", "summary"), default="summary")
    args = parser.parse_args()
    if args.ingest:
        if sys.platform != "linux":
            parser.error("ROUTER_OWNER: history persistence belongs to the Linux owner host")
        print(json.dumps(ingest(args.state_dir, json.load(sys.stdin))))
        return
    rows = read_history(args.state_dir.resolve(), args.include_archives, "event" if args.events else "observation")
    if args.format == "json":
        print(json.dumps(rows, indent=2))
    elif args.format == "csv":
        if rows:
            out = csv.DictWriter(sys.stdout, fieldnames=list(rows[0]))
            out.writeheader()
            out.writerows({k: json.dumps(v) if isinstance(v, dict) else v for k, v in row.items()} for row in rows)
    else:
        print(f"{len(rows)} {'events' if args.events else 'observations'}; archives {'included' if args.include_archives else 'excluded'}; reset causes unknown")
        for row in rows:
            stamp = row.get("observed_at_utc", row.get("interval_end_utc"))
            et = datetime.fromisoformat(stamp).astimezone(ZoneInfo("America/New_York")).strftime("%Y-%m-%d %I:%M %p ET")
            reset = row.get("resets_at_utc", row.get("new_reset_at_utc"))
            reset_et = datetime.fromisoformat(reset).astimezone(ZoneInfo("America/New_York")).strftime("%Y-%m-%d %I:%M %p ET") if reset else "unknown"
            detail = row.get("kind", str(row.get("used_percent")) + "% used")
            if "old_used_percent" in row:
                detail += f" {row['old_used_percent']}% -> {row['new_used_percent']}%"
            print(f"{et} {row['vendor']} {row['limit_id']}/{row['window_id']}: {detail}; resets {reset_et} ({row['provenance']})")


if __name__ == "__main__":
    main()
