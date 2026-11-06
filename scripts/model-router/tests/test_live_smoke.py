"""Offline coverage of live-smoke.ps1. Every CLI is fake and no test passes -Live.

The driver dot-sources the script, which launches nothing, and calls its function with
runners that use disposable entry copies whose Live gates are removed.
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

from test_bench_protocol_repair import fake_smoke

for _name in ('DT_JOB_ID', 'DT_JOB_DIR', 'DT_BUILD_COORDINATOR_ID'):
    os.environ.pop(_name, None)

TESTS = Path(__file__).resolve().parent
ROUTER = TESTS.parent
REPO = ROUTER.parents[1]
EXPECTED = '2026-11-05T05:01:00Z'
ROSTER_BYTES = (REPO / 'references/model-router/default-roster.json').read_bytes()

DRIVER = r"""
param([string]$Case,[string]$Out,[string]$Source,[string]$SmokeEntry,[string]$DispatchEntry,[string]$FakeBin,[string]$Tests)
foreach ($name in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID')) { Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue }
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $Tests 'live-smoke.ps1')
. (Join-Path $Tests '../send-router-alert.ps1')
. (Join-Path $Tests 'fixtures/router-test-codex-home.ps1')
$fixture=Enter-RouterTestCodexHome
$catalogPath=Join-Path $env:CODEX_HOME 'models_cache.json'
$catalog=Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -Depth 20
foreach ($row in $catalog.models) { $row | Add-Member -Force -NotePropertyName supported_reasoning_levels -NotePropertyValue @(@{effort='low'},@{effort='medium'},@{effort='high'}) }
[IO.File]::WriteAllText($catalogPath,(ConvertTo-Json -InputObject $catalog -Depth 20),[Text.UTF8Encoding]::new($false))
$dispatchPath=$env:PATH
$code=99
try {
    $transport={
        param($Vendor,$Directory,$LogPath)
        if ($Case -ceq 'transport-exit0-status-unknown') {
            [IO.File]::WriteAllText((Join-Path $Directory 'smoke-transport.json'),'{"status":"unknown","model":"m","events":[]}')
            return 0
        }
        if ($Case -ceq 'transport-exit0-no-file') { return 0 }
        $env:PATH=$FakeBin+[IO.Path]::PathSeparator+$dispatchPath
        try { & pwsh -NoProfile -NonInteractive -File $SmokeEntry -Vendor $Vendor -OutDir $Directory *> $LogPath; $LASTEXITCODE }
        finally { $env:PATH=$dispatchPath }
    }
    $dispatch={
        param($Vendor,$Arguments,$LogPath)
        if ($Case -ceq 'alert-attempt') { $null=Send-RouterAlert -Key 'fixture-alert' -Message 'fixture' -ChatToStderr }
        $mode=if ($Case -ceq 'dispatch-no-rollout' -and $Vendor -ceq 'codex') { 'no-rollout' } else { '' }
        $env:M04_FAKE_MODE=$mode
        & pwsh -NoProfile -NonInteractive -File $DispatchEntry @Arguments *> $LogPath
        $LASTEXITCODE
    }
    $call=@{Destination=$Out;SourceState=$Source;TransportRunner=$transport;DispatchRunner=$dispatch}
    if ($Case -ceq 'quota-blocked') {
        $call.QuotaGuard={ param($Vendor) [pscustomobject]@{status=$(if ($Vendor -ceq 'claude') {'wait'} else {'ok'});reason='fixture quota';model='fixture-model'} }
    } else {
        $call.QuotaGuard={ param($Vendor) [pscustomobject]@{status='ok';reason='fixture';model='fixture-model'} }
    }
    if ($Case -ceq 'report-missing') { $call.ReportRunner={ param($StateDir,$LogPath) [IO.File]::WriteAllText($LogPath,'no report'); 0 } }
    $code=Invoke-RouterLiveSmoke @call
} finally { Exit-RouterTestCodexHome $fixture }
exit $code
"""


def clean_env() -> dict[str, str]:
    env = dict(os.environ)
    for name in ('DT_JOB_ID', 'DT_JOB_DIR', 'DT_BUILD_COORDINATOR_ID'):
        env.pop(name, None)
    return env


def hard_copy(source: Path, destination: Path, *replacements: tuple[str, str]) -> Path:
    text = source.read_text(encoding='utf-8')
    for old, new in replacements:
        assert old in text, old
        text = text.replace(old, new)
    destination.write_text(text.replace('$PSScriptRoot', "'" + str(source.parent).replace("'", "''") + "'"), encoding='utf-8')
    return destination


@pytest.fixture
def harness(tmp_path, monkeypatch):
    for name in ('DT_JOB_ID', 'DT_JOB_DIR', 'DT_BUILD_COORDINATOR_ID'):
        monkeypatch.delenv(name, raising=False)
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()

    def build(*, invalid: bool = False):
        auth = bin_dir / 'auth'
        if auth.exists():
            (auth / 'auth.json').unlink()
            auth.rmdir()
        entry = fake_smoke(bin_dir, monkeypatch, invalid=invalid)
        smoke = bin_dir / 'smoke-fixture.ps1'
        fake_claude = bin_dir / 'claude-bench.ps1'
        fake_claude.write_text(
            "$null=[Console]::In.ReadToEnd()\n"
            "$model=$args[[array]::IndexOf($args,'--model')+1]\n"
            "$usage=@{}; $usage[$model]=@{inputTokens=1;outputTokens=1}\n"
            "@{type='result';result='OK';is_error=$false;modelUsage=$usage} | ConvertTo-Json -Compress -Depth 5\n",
            encoding='utf-8')
        resolver = "{ '" + str(fake_claude).replace("'", "''") + "' }"
        text = entry.read_text(encoding='utf-8')
        text = text.replace('-Request $request -TimeoutMs 120000', '-Request $request -TimeoutMs 120000 -ClaudeResolver ' + resolver)
        text = text.replace("first='claude-synthetic';", "first='claude-synthetic';first_effort='low';")
        assert '-ClaudeResolver' in text and 'first_effort' in text
        smoke.write_text(text, encoding='utf-8')
        return smoke

    dispatch = hard_copy(ROUTER / 'dispatch.ps1', tmp_path / 'dispatch-fixture.ps1',
        ("if (-not $Live) { throw 'DISPATCH_LIVE_REQUIRED: model calls require -Live' }", '# Fixture copy: fake CLIs only.'),
        ("if (-not $Options['Live']) { throw 'DISPATCH_LIVE_REQUIRED: model calls require -Live' }", '# Fixture copy: fake CLIs only.'))
    source = tmp_path / 'source-state'
    source.mkdir()
    (source / 'roster.json').write_bytes(ROSTER_BYTES)
    (source / 'bench' / 'runs').mkdir(parents=True)
    (source / 'bench' / 'runs' / 'huge.bin').write_text('never copied')
    sweep = tmp_path / 'noop-sweep.py'
    sweep.write_text('import sys\n')
    answer = tmp_path / 'answer.txt'
    answer.write_text(EXPECTED, encoding='utf-8')
    fake_args = tmp_path / 'fake-args.log'
    fake_args.write_text('')
    driver = tmp_path / 'driver.ps1'
    driver.write_text(DRIVER, encoding='utf-8')

    def run(case: str = 'ok', *, invalid: bool = False, out: Path | None = None):
        smoke = build(invalid=invalid)
        monkeypatch.setenv('DT_MODEL_ROUTER_USAGE_SWEEP', str(sweep))
        monkeypatch.setenv('M04_FAKE_ARGS', str(fake_args))
        monkeypatch.setenv('M04_FAKE_REPORT', str(answer))
        monkeypatch.setenv('DT_MODEL_ROUTER_STATE', str(source))
        destination = out or tmp_path / 'audit'
        process = subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', str(driver),
            '-Case', case, '-Out', str(destination), '-Source', str(source), '-SmokeEntry', str(smoke),
            '-DispatchEntry', str(dispatch), '-FakeBin', str(bin_dir), '-Tests', str(TESTS)],
            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=240, env=clean_env(), stdin=subprocess.DEVNULL)
        path = destination / 'live-smoke-result.json'
        assert path.exists(), process.stderr[-2000:] + process.stdout[-2000:]
        return process, json.loads(path.read_text(encoding='utf-8')), destination

    return run, source, answer, fake_args


def test_all_pass_records_semantics_and_writes_only_audit_folder(harness):
    run, source, _answer, fake_args = harness
    process, result, out = run()
    assert process.returncode == 0, json.dumps(result, indent=1)[:4000]
    assert result['status'] == 'ok' and result['error'] is None
    assert result['acceptance'].startswith('execution only')
    for vendor in ('codex', 'claude'):
        item = result['vendors'][vendor]
        assert item['status'] == 'ok'
        assert item['transport']['status'] == 'ok' and item['transport']['process_exit'] == 0
        records = {e['method']: e['observation'] for e in item['transport']['events']}
        assert records and set(records.values()) <= {'seen', 'not-exercised'}
        dispatch = item['dispatch']
        assert dispatch['status'] == 'ok' and dispatch['byte_exact'] is True
        # A date-shaped answer comes back as the same string through the real wrapper.
        assert dispatch['actual_text'] == dispatch['expected_text'] == EXPECTED
        assert dispatch['independent_acceptance'] is None
        assert (Path(result['attempt']) / vendor / 'dispatch-answer.txt').read_bytes() == EXPECTED.encode()
    assert {'rawResponseItem/completed': 'seen'}.items() <= {
        e['method']: e['observation'] for e in result['vendors']['codex']['transport']['events']}.items()
    assert result['report']['status'] == 'ok' and Path(result['report']['path']).is_file()
    assert Path(result['report']['path']).is_relative_to(out)
    # No live roster write, no benchmark copy, one tiny dispatch per vendor with no tools.
    assert result['live_roster_unchanged'] is True
    assert (source / 'roster.json').read_bytes() == ROSTER_BYTES
    assert sorted(p.name for p in source.iterdir()) == ['.gitignore', 'bench', 'roster.json'] or \
        sorted(p.name for p in source.iterdir()) == ['bench', 'roster.json']
    assert not (Path(result['attempt']) / 'state/bench/runs').exists()
    calls = [line for line in fake_args.read_text().splitlines() if line]
    assert sorted(line.split('|')[0] for line in calls) == ['claude', 'codex']
    claude_call = next(line.split('|') for line in calls if line.startswith('claude|'))
    assert claude_call[claude_call.index('--tools') + 1] == ''
    assert result['notifications'] == {'mode': 'off', 'suppressed_requests': 0}
    note = (out / 'tie-follow-up.md').read_text(encoding='utf-8')
    assert result['tie_follow_up'] == str(out / 'tie-follow-up.md')
    assert 'This note approves nothing' in note and 'Old tie approvals stay invalid' in note


@pytest.mark.parametrize('case,invalid,vendor_field,status', [
    ('transport-exit0-status-unknown', False, 'transport', 'unknown'),
    ('transport-exit0-no-file', False, 'transport', 'missing'),
    ('ok', True, 'transport', 'unknown'),
    ('dispatch-no-rollout', False, 'dispatch', 'unknown_model'),
])
def test_non_ok_saved_result_exits_nonzero_without_note(harness, case, invalid, vendor_field, status):
    run, *_ = harness
    process, result, out = run(case, invalid=invalid)
    assert process.returncode == 1
    assert result['status'] == 'failed'
    assert result['vendors']['codex'][vendor_field]['status'] == status
    if case.startswith('transport-exit0'):
        # The process exited 0 and still cannot read as a pass.
        assert result['vendors']['codex']['transport']['process_exit'] == 0
    assert result['tie_follow_up'] is None and not (out / 'tie-follow-up.md').exists()


def test_changed_date_answer_fails_byte_exact(harness):
    run, _source, answer, _args = harness
    answer.write_text('11/05/2026 05:01:00', encoding='utf-8')
    process, result, out = run()
    assert process.returncode == 1
    dispatch = result['vendors']['claude']['dispatch']
    assert dispatch['status'] == 'answer_changed' and dispatch['byte_exact'] is False
    assert dispatch['execution_result'] == 'success'
    assert not (out / 'tie-follow-up.md').exists()


def test_quota_guard_stops_that_vendor_before_any_call(harness):
    run, _source, _answer, fake_args = harness
    process, result, out = run('quota-blocked')
    assert process.returncode == 1
    claude = result['vendors']['claude']
    assert claude['status'] == 'quota_blocked' and claude['quota']['reason'] == 'fixture quota'
    assert claude['transport']['status'] == 'not_run' and claude['dispatch']['status'] == 'not_run'
    assert not any(line.startswith('claude|') for line in fake_args.read_text().splitlines())
    assert result['vendors']['codex']['status'] == 'ok'
    assert not (out / 'tie-follow-up.md').exists()


def test_missing_report_fails_even_when_both_vendors_pass(harness):
    run, *_ = harness
    process, result, out = run('report-missing')
    assert process.returncode == 1
    assert result['vendors']['codex']['ok'] is True and result['vendors']['claude']['ok'] is True
    assert result['report']['status'] == 'failed'
    assert not (out / 'tie-follow-up.md').exists()


def test_alert_attempt_is_refused_and_counted(harness):
    run, *_ = harness
    process, result, _out = run('alert-attempt')
    assert process.returncode == 0, json.dumps(result, indent=1)[:3000]
    assert result['notifications']['suppressed_requests'] > 0


def test_failed_rerun_removes_an_earlier_pass_note(harness):
    run, *_ = harness
    first, passed, out = run()
    assert first.returncode == 0 and (out / 'tie-follow-up.md').exists()
    second, failed, _ = run('transport-exit0-no-file', out=out)
    assert second.returncode == 1 and failed['status'] == 'failed'
    assert failed['attempt'] != passed['attempt']
    assert not (out / 'tie-follow-up.md').exists()


@pytest.mark.parametrize('args,message', [
    ([], 'LIVE_SMOKE_OUTDIR_REQUIRED'),
    (['-OutDir', 'PLACEHOLDER'], 'LIVE_SMOKE_LIVE_REQUIRED'),
])
def test_entry_refuses_fast_without_prompting(tmp_path, args, message):
    # No -NonInteractive here: the gate command omits it, so a mandatory prompt would hang.
    target = tmp_path / 'probe'
    args = [str(target) if a == 'PLACEHOLDER' else a for a in args]
    result = subprocess.run(['pwsh', '-NoProfile', '-File', str(TESTS / 'live-smoke.ps1'), *args],
        capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=30, env=clean_env(), stdin=subprocess.DEVNULL)
    assert result.returncode != 0
    assert message in result.stderr
    assert not target.exists()


def test_release_document_retains_limitations():
    text = (REPO / 'references/model-router/dispatch-guard-release.md').read_text(encoding='utf-8')
    for phrase in ('`exec` and `wait`', 'Workflow inner agents', 'measured only', 'thread/prediction/updated',
                   'thread/readState/changed', 'ten retained prefix failures', '2026-10-07'):
        assert phrase in text
    methods = json.loads((ROUTER / 'bench/appserver-methods.json').read_text(encoding='utf-8'))
    assert 'thread/prediction/updated' not in methods and 'thread/readState/changed' not in methods


def test_script_starts_no_benchmark_and_no_frontier_path():
    text = (TESTS / 'live-smoke.ps1').read_text(encoding='utf-8')
    for forbidden in ('run-bench.ps1', 'request-frontier', 'FrontierRequest', 'publish-roster', 'approve-roster', 'Send-RouterAlert'):
        assert forbidden not in text
