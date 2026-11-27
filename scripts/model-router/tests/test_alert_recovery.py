"""Disposable ledger and stub transport only; no vendor CLI or delivery."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import time

import pytest

ROOT = Path(__file__).resolve().parents[3]
SENDER = ROOT / 'scripts/model-router/send-router-alert.ps1'


def run(state, body, *, check=True):
    env = dict(os.environ, DT_MODEL_ROUTER_STATE=str(state))
    code = f". '{SENDER}'; " + r'''
$fake = { param($r)
    if ($r.kind -eq 'secret') { return 'fixture' }
    if ($r.uri -like '*/applications/@me') { return [pscustomobject]@{ owner=@{id='fixture'} } }
    return [pscustomobject]@{id='fixture'}
}
function Send([string]$Key, [string]$Vendor='codex', [string]$ErrorText='Login failed', [string]$At='2026-11-27T10:00:00Z', [bool]$Probe=$true) {
    Send-RouterAlert -Key $Key -Message 'fixture' -Vendor $Vendor -ErrorText $ErrorText -Probe:$Probe -Now ([datetimeoffset]$At) -Transport $fake -ChatToStderr
}
''' + body
    result = subprocess.run(['pwsh', '-NoProfile', '-Command', code], env=env,
                            text=True, capture_output=True, timeout=90)
    if check:
        assert result.returncode == 0, result.stderr
    return result


def result(state, body):
    return json.loads(run(state, '(' + body + ') | ConvertTo-Json -Compress').stdout)


def events(state):
    return [json.loads(line) for line in (state / 'alert-log.jsonl').read_text().splitlines()]


def test_rolling_hour_and_normalization(tmp_path):
    assert result(tmp_path, "Send 'run1'")['sent']
    assert result(tmp_path, "Send 'run2' 'codex' '  LOGIN   failed  ' '2026-11-27T10:59:59Z'")['deduped']
    assert not result(tmp_path, "Send 'run3' 'codex' 'Login failed' '2026-11-27T11:00:00Z'")['deduped']
    assert result(tmp_path, "Send 'run4' 'codex' 'Login failed' '2026-11-27T11:59:59Z'")['deduped']
    assert len(events(tmp_path)) == 2  # suppressed calls do not extend the delivery window or grow state


@pytest.mark.parametrize('stamp', ['2026-11-27T10:00:00Z', '2026-11-27T05:00:00-05:00'])
def test_timestamp_representation_does_not_change_hour(tmp_path, stamp):
    result(tmp_path, "Send 'first'")
    row = events(tmp_path)[0]
    row['at'] = stamp
    (tmp_path / 'alert-log.jsonl').write_text(json.dumps(row) + '\n')
    assert result(tmp_path, "Send 'second' 'codex' 'Login failed' '2026-11-27T10:59:59Z'")['deduped']
    assert not result(tmp_path, "Send 'expired' 'codex' 'Login failed' '2026-11-27T11:00:00Z'")['deduped']


@pytest.mark.parametrize('vendor,error', [('claude', 'Login failed'), ('codex', 'Permission denied'), ('codex', 'Login failed request 2')])
def test_distinct_errors_and_vendors(tmp_path, vendor, error):
    result(tmp_path, "Send 'run1'")
    assert not result(tmp_path, f"Send 'run2' '{vendor}' '{error}'")['deduped']


def test_recovery_preserves_other_lane_and_work(tmp_path):
    result(tmp_path, "Send 'probe1'")
    result(tmp_path, "Send 'probe2' 'codex' 'Other failure'")
    result(tmp_path, "Send 'claude1' 'claude'")
    result(tmp_path, "Send 'work1' 'codex' 'Work failure' '2026-11-27T10:00:00Z' $false")
    run(tmp_path, "Complete-RouterProbeRecovery -Vendor codex -StartedAt ([datetimeoffset]'2026-11-27T10:01:00Z')")
    acknowledged = [e['key'] for e in events(tmp_path) if e['event'] == 'acknowledged']
    assert set(acknowledged) == {'probe1', 'probe2'}
    assert not result(tmp_path, "Send 'probe3' 'codex' 'Login failed' '2026-11-27T10:02:00Z'")['deduped']
    assert result(tmp_path, "Send 'claude2' 'claude' 'Login failed' '2026-11-27T10:02:00Z'")['deduped']


def test_recovery_does_not_clear_newer_failure(tmp_path):
    result(tmp_path, "Send 'older'")
    result(tmp_path, "Send 'newer' 'codex' 'Different' '2026-11-27T10:02:00Z'")
    run(tmp_path, "Complete-RouterProbeRecovery -Vendor codex -StartedAt ([datetimeoffset]'2026-11-27T10:01:00Z')")
    assert [e['key'] for e in events(tmp_path) if e['event'] == 'acknowledged'] == ['older']


def test_work_alert_cannot_hide_or_rearm_a_probe(tmp_path):
    assert result(tmp_path, "Send 'work' 'codex' 'Login failed' '2026-11-27T10:00:00Z' $false")['sent']
    assert not result(tmp_path, "Send 'probe'")['deduped']
    run(tmp_path, "Complete-RouterProbeRecovery -Vendor codex -StartedAt ([datetimeoffset]'2026-11-27T10:01:00Z')")
    assert not result(tmp_path, "Send 'next' 'codex' 'Login failed' '2026-11-27T10:02:00Z'")['deduped']
    assert result(tmp_path, "Send 'other-work' 'codex' 'Login failed' '2026-11-27T10:02:00Z' $false")['deduped']


def test_failed_delivery_does_not_suppress_retry(tmp_path):
    failed = result(tmp_path, "& { $fake={throw 'fixture unavailable'}; Send 'failed' }")
    assert not failed['sent']
    assert not result(tmp_path, "Send 'retry'")['deduped']


def test_legacy_probe_requires_exact_outcome_evidence(tmp_path):
    ids = ['a' * 32, 'b' * 32, 'c' * 32]
    rows = [{'event': 'delivered', 'key': 'vendor-error:codex:' + i,
             'at': '2026-11-27T10:00:00Z'} for i in ids]
    (tmp_path / 'alert-log.jsonl').write_text('\n'.join(json.dumps(r) for r in rows) + '\nmalformed\n')
    (tmp_path / '_archive').mkdir()
    (tmp_path / '_archive/outcomes-2026-11-27.jsonl').write_text(json.dumps({
        'key': ids[0] + ':preflight', 'source': 'canary', 'run_id': 'preflight',
        'lane': 'codex', 'pass': False}) + '\n')
    (tmp_path / 'outcomes.jsonl').write_text(json.dumps({
        'key': ids[1] + ':preflight', 'source': 'canary', 'run_id': 'preflight',
        'lane': 'claude', 'pass': False}) + '\n')
    run(tmp_path, "Complete-RouterProbeRecovery -Vendor codex -StartedAt ([datetimeoffset]'2026-11-27T10:01:00Z')")
    rows = [json.loads(s) for s in (tmp_path / 'alert-log.jsonl').read_text().splitlines() if s != 'malformed']
    assert [r['key'] for r in rows if r['event'] == 'acknowledged'] == ['vendor-error:codex:' + ids[0]]
    # Legacy untyped deliveries and acknowledgements retain exact-key behavior.
    assert result(tmp_path, "Send-RouterAlert -Key 'vendor-error:codex:" + ids[2] + "' -Message 'fixture' -Transport $fake")['deduped']
    assert not result(tmp_path, "Send 'new-probe'")['deduped']


def test_default_window_starts_after_confirmed_delivery(tmp_path):
    observed = result(tmp_path, r'''& {
        $originalFake=$fake
        $fake={ param($r)
            $reply = & $originalFake $r
            if ($r['uri'] -like '*/channels/*/messages') { $script:confirmed=[datetimeoffset]::UtcNow }
            return $reply
        }
        $null=Send-RouterAlert -Key 'real-clock' -Message 'fixture' -Vendor codex -ErrorText 'fixture' -Probe -Transport $fake -ChatToStderr
        $row=@(Read-RouterAlertEvents (Join-Path $env:DT_MODEL_ROUTER_STATE 'alert-log.jsonl'))[0]
        [pscustomobject]@{recorded_after_confirmation=([datetimeoffset]$row.at -ge $script:confirmed)}
    }''')
    assert observed['recorded_after_confirmation']


def test_recovery_waits_for_inflight_delivery_mutex(tmp_path):
    result(tmp_path, "Send 'pending-probe'")
    holder = r'''
$m=[Threading.Mutex]::new($false, 'Local\DtModelRouterAlert')
try {
    $null=$m.WaitOne()
    [IO.File]::WriteAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'held'), 'ready')
    while (-not (Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'release'))) { Start-Sleep -Milliseconds 50 }
} finally { $m.ReleaseMutex(); $m.Dispose() }
'''
    def await_marker(name):
        deadline = time.monotonic() + 60
        while not (tmp_path / name).exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert (tmp_path / name).exists()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        holding = pool.submit(run, tmp_path, holder)
        try:
            await_marker('held')
            recovering = pool.submit(run, tmp_path,
                "[IO.File]::WriteAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'recovering'), 'ready'); "
                "Complete-RouterProbeRecovery -Vendor codex -StartedAt ([datetimeoffset]'2026-11-27T10:01:00Z')", check=False)
            await_marker('recovering')
            # This is a deliberately held lock, not an estimate of child startup time.
            # Recovery must retain its only success signal beyond the sender's 5s busy timeout.
            with pytest.raises(concurrent.futures.TimeoutError):
                recovering.result(timeout=10)
        finally:
            (tmp_path / 'release').write_text('release')
            holding.result()
        assert recovering.result().returncode == 0
    assert [r['key'] for r in events(tmp_path) if r['event'] == 'acknowledged'] == ['pending-probe']


def test_concurrent_unique_dispatch_ids(tmp_path):
    def send(i):
        return run(tmp_path, f"[IO.File]::WriteAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'ready{i}'), 'ready'); " +
                   "while (-not (Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'go'))) { Start-Sleep -Milliseconds 50 }; " +
                   f"Send 'concurrent{i}' | ConvertTo-Json -Compress")
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        calls = [pool.submit(send, i) for i in range(4)]
        deadline = time.monotonic() + 60
        while len(list(tmp_path.glob('ready*'))) < 4 and time.monotonic() < deadline:
            time.sleep(.05)
        (tmp_path / 'go').write_text('go')
        answers = [json.loads(f.result().stdout) for f in calls]
    assert all(a['sent'] for a in answers)
    assert sum(not a['deduped'] for a in answers) == 1
    assert len(events(tmp_path)) == 1
