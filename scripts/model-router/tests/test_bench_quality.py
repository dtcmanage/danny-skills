from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import subprocess
import sys

import pytest

BENCH = Path(__file__).resolve().parents[1] / 'bench'
sys.path.insert(0, str(BENCH))
import bench_engine as engine
from review import Review


@pytest.fixture(autouse=True)
def isolate_synthetic_inputs(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(engine, 'CANDIDATE_INPUTS', dict(engine.CANDIDATE_INPUTS))
    for key, leaf in {'CLAUDE_CONFIG_DIR': 'claude', 'DT_MODEL_ROUTER_CLAUDE_CREDENTIALS': 'missing-credentials.json',
                      'CODEX_HOME': 'codex', 'DT_MODEL_ROUTER_CODEX_SESSIONS': 'sessions'}.items():
        monkeypatch.setenv(key, str(tmp_path / 'isolated' / leaf))
    for key in ('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN',
                'CLAUDE_CODE_OAUTH_TOKEN', 'OPENAI_ACCESS_TOKEN'):
        monkeypatch.delenv(key, raising=False)


def tasks(root: Path, job: str, tiers: tuple[str, ...] = ('standard',), count: int = 1) -> Path:
    for tier in tiers:
        for index in range(count):
            task = root / f'normal-{tier}-{index}'
            task.mkdir(parents=True)
            (task / 'task.json').write_text(json.dumps(dict(id=task.name, job=job,
                category='planning', grader='exact', difficulty=tier)))
            (task / 'prompt.md').write_text('Answer ok.')
            (task / 'known-good.txt').write_text('ok')
            engine.CANDIDATE_INPUTS[task.name] = ()  # Synthetic fixture has no candidate input files.
    task = root / 'ranked-synthetic'
    task.mkdir(parents=True)
    (task / 'task.json').write_text(json.dumps(dict(id=task.name, job=job,
        category='planning', grader='ranked', tiers=list(tiers))))
    (task / 'prompt.md').write_text('Compare synthetic plans.')
    (task / 'criteria.md').write_text('- Clear plan.\n')
    return root


def run(tmp_path: Path, job: str = 'coder', preference: str = 'higher',
        tiers: tuple[str, ...] = ('standard',), normal: str = 'pass', ranked: bool = True,
        spend_check: object = None, count: int = 1, config_extra: dict | None = None,
        higher_status: str | None = None) -> dict:
    root = tasks(tmp_path / 'tasks', job, tiers, count)
    if not ranked:
        import shutil
        shutil.rmtree(root / 'ranked-synthetic')
    state = tmp_path / 'state'
    state.mkdir(parents=True)
    (state / 'roster.json').write_text(json.dumps({'jobs': {job: {
        'first': 'incumbent', 'backup': 'candidate', 'first_effort': 'medium', 'backup_effort': 'medium',
        'first_efforts': {'standard': 'medium', 'hard': 'high'},
        'backup_efforts': {'standard': 'medium', 'hard': 'high'}}}}))
    service = Review(root, state / 'bench')
    approval = service.refresh()
    approval['approved'] = True
    approval['tasks'] = {task_id: 'approved' for task_id in service.ids}
    service.approval_path.write_text(json.dumps(approval))
    def dispatch(request: dict) -> dict:
        if request['purpose'] == 'answer':
            if preference == 'outage':
                return {'status': 'unknown', 'detail': 'synthetic outage'}
            return {'status': 'ok', 'answer': request['model'] + ':' + request['effort']}
        if preference in ('no_difference', 'invalid'):
            return {'status': 'ok', 'answer': 'no_difference' if preference == 'no_difference' else 'bad'}
        outputs = re.findall(r'BEGIN OUTPUT [AB] [a-f0-9]+\n([^\n]+)', request['prompt'])
        assert len(outputs) == 2
        if preference in ('candidate', 'incumbent'):
            chosen = next((i for i, a in enumerate(outputs) if a.startswith(preference + ':')), 0)
        else:
            levels = {'low': 0, 'medium': 1, 'high': 2, 'xhigh': 3}
            scores = [levels[a.split(':')[1]] for a in outputs]
            chosen = scores.index(max(scores) if preference == 'higher' else min(scores))
        return {'status': 'ok', 'answer': 'A' if chosen == 0 else 'B'}
    return engine.run_bench(job=job, candidate='candidate', incumbent='incumbent', trigger='manual',
        effort='medium', state_dir=state, tasks=root,
        config={'judges': {'claude': 'claude-judge', 'codex': 'codex-judge'},
                'judge_effort': 'high', **(config_extra or {})},
        dispatch=dispatch, limits=lambda v: {'blocked': False}, envelope=lambda a: a,
        outcome=lambda r: None, grade=lambda t, a: {'status': higher_status if higher_status and a == 'incumbent:high' else normal},
        roster_entry={'first': 'incumbent', 'backup': 'candidate',
            'first_efforts': {'standard': 'medium', 'hard': 'high'},
            'backup_efforts': {'standard': 'medium', 'hard': 'high'}},
        effort_override=False, spend_check=spend_check)


@pytest.mark.parametrize('preference,allowed', [('incumbent', False), ('candidate', True), ('no_difference', True)])
def test_swap_quality_gate(tmp_path: Path, preference: str, allowed: bool) -> None:
    result = run(tmp_path, preference=preference)['tiers'][0]
    assert result['raw_gate'] == 'pass'
    assert result['swap_qualified'] is allowed
    evidence = result['quality_evidence']
    assert evidence['tier'] == 'standard' and evidence['run_id'] == Path(result['report_paths']['json']).parent.name
    assert evidence['configurations'] == result['configurations']


@pytest.mark.parametrize('job', ['coder', 'deep-thinker', 'writer'])
def test_higher_effort_wins_equal_passes(tmp_path: Path, job: str) -> None:
    result = run(tmp_path, job=job, tiers=('standard', 'hard') if job != 'writer' else ('standard',))
    measured = result.get('tiers', [result])
    standard = measured[0]
    assert standard['effort_up_qualified'] and not standard['effort_down_qualified']
    assert standard['incumbent']['passed'] == standard['effort_up']['passed']
    assert standard['effort_up_quality_verdict']['configurations']['candidate']['effort'] == 'high'
    if job != 'writer':
        assert standard['effort_down_quality_verdict']['verdict'] == 'incumbent_better'
        assert standard['effort_down_quality_verdict']['configurations']['candidate']['effort'] == 'low'
        assert not measured[1]['effort_up_qualified'] and measured[1]['tier'] == 'hard'
        assert result['quality_verdict'] is None
        assert all(result[field] is None for field in ('quality_evidence', 'effort_down_quality_verdict',
            'effort_up_quality_verdict', 'effort_down_quality_evidence', 'effort_up_quality_evidence'))
        assert not result['swap_qualified'] and not result['tie_qualified']
    else:
        assert standard['effort_down'] is None


def test_lower_effort_wins(tmp_path: Path) -> None:
    standard = run(tmp_path, preference='lower')['tiers'][0]
    assert standard['effort_down_qualified'] and not standard['effort_up_qualified']
    assert standard['effort_down_quality_verdict']['verdict'] == 'candidate_better'


@pytest.mark.parametrize('status,qualifies', [('fail', False), ('unknown', False), ('pass', True)])
@pytest.mark.parametrize('job', ['coder', 'deep-thinker', 'writer'])
def test_quality_effort_up_requires_known_no_fewer_passes(tmp_path: Path, status: str, qualifies: bool, job: str) -> None:
    result = run(tmp_path, job=job, higher_status=status)
    standard = result.get('tiers', [result])[0]
    assert standard['effort_up_quality_verdict']['verdict'] == 'candidate_better'
    assert standard['effort_up_qualified'] is qualifies


@pytest.mark.parametrize('preference,qualifies', [('candidate', False), ('incumbent', False),
    ('no_difference', True), ('invalid', False), ('outage', False)])
def test_tie_requires_decided_no_difference(tmp_path: Path, preference: str, qualifies: bool) -> None:
    standard = run(tmp_path, preference=preference)['tiers'][0]
    assert standard['tie_qualified'] is qualifies
    proposal = tmp_path / 'state/tie-proposals/coder.json'
    assert proposal.exists() is qualifies
    if qualifies:
        recorded = json.loads(proposal.read_text())['quality_evidence']
        assert recorded['verdict'] == 'no_difference' and recorded['tier'] == 'standard'
    if preference == 'outage':
        assert standard['quality_verdict']['verdict'] == 'no_difference'
        assert all(d['reason'] == 'answer_unavailable' for d in standard['quality_verdict']['tasks'][0]['disagreements'])


@pytest.mark.parametrize('normal', ['pass', 'fail'])
def test_null_quality_preserves_behavior(tmp_path: Path, normal: str) -> None:
    standard = run(tmp_path, ranked=False, normal=normal)['tiers'][0]
    assert standard['quality_verdict'] is None
    assert standard['effort_down_qualified'] is (normal == 'pass')
    assert standard['tie_qualified'] is (normal == 'pass')
    assert not standard['effort_up_qualified']
    assert (tmp_path / 'state/tie-proposals/coder.json').exists() is (normal == 'pass')


@pytest.mark.parametrize('preference,evidence', [('higher', True), ('no_difference', True), ('invalid', False)])
def test_quality_evidence_overrides_uninformative_passes(tmp_path: Path, preference: str, evidence: bool) -> None:
    standard = run(tmp_path, normal='fail', preference=preference)['tiers'][0]
    assert standard['insufficient_evidence'] is (not evidence)
    assert standard['effort_up_qualified'] is (preference == 'higher')
    assert standard['effort_down_qualified'] is (preference == 'no_difference')
    assert not standard['tie_qualified']  # Existing parity gate still required.


def test_spend_more_than_five_points_between_tasks(tmp_path: Path) -> None:
    readings = iter([10, 15, 15.1])
    def check() -> dict:
        return {'claude': {'used_percent': next(readings)}, 'codex': {'used_percent': 10}}
    result = run(tmp_path, job='fast', ranked=False, count=2, spend_check=check)
    assert result['halted'] and result['spend']['model_calls'] == 3
    assert result['spend']['latest']['claude']['used_percent'] == 15.1
    assert 'claude weekly use moved' in result['halt_reason']
    assert json.loads(Path(result['report_paths']['json']).read_text())['halted']
    assert not (tmp_path / 'state/tie-proposals').exists()
    assert not (tmp_path / 'state/effort-proposals').exists()
    next_job = run(tmp_path / 'next', job='fast', ranked=False,
        spend_check=lambda: {'claude': {'used_percent': 10}, 'codex': {'used_percent': 10}})
    assert not next_job.get('halted', False)


@pytest.mark.parametrize('reading', [None, {'measurement': 'unavailable'},
    {'used_percent': 1, 'stale': True}, {'used_percent': 1, 'observed_at_utc': '2000-01-01T00:00:00Z'}])
def test_unavailable_or_stale_450_call_cap(tmp_path: Path, reading: dict | None) -> None:
    result = run(tmp_path, job='fast', count=60, ranked=False,
        spend_check=lambda: {'claude': reading, 'codex': {'used_percent': 10}})
    assert result['halted'] and result['spend']['model_calls'] == 450
    assert '450/450' in result['halt_reason']
    assert not (tmp_path / 'state/tie-proposals').exists()


def test_named_threshold_overrides(tmp_path: Path) -> None:
    result = run(tmp_path, job='fast', ranked=False, count=2,
        spend_check=lambda: {}, config_extra={'spend_stop_model_calls': 4})
    assert result['halted'] and result['spend']['model_calls'] == 4


def test_no_proposal_from_completed_tier_when_later_tier_halts(tmp_path: Path) -> None:
    boundaries = 0
    def check() -> dict:
        nonlocal boundaries
        boundaries += 1
        return {'claude': {'used_percent': 16 if boundaries >= 9 else 10},
                'codex': {'used_percent': 10}}
    result = run(tmp_path, preference='no_difference', tiers=('standard', 'hard'), spend_check=check)
    assert result['halted'] and result['spend']['model_calls'] == 48
    assert not (tmp_path / 'state/tie-proposals').exists()
    reports = [json.loads(p.read_text()) for p in (tmp_path / 'state/bench/runs').glob('*/report.json')]
    assert len(reports) >= 2 and all(r['halted'] for r in reports)
    completed = next(r for r in reports if r.get('tier') == 'standard')
    assert completed['halt_reason'] == result['halt_reason']
    assert 'Comparison halted:' in Path(completed['report_paths']['markdown']).read_text()


@pytest.mark.parametrize('initial', [None, 'stale'])
def test_first_fresh_reading_replaces_missing_baseline(initial: str | None) -> None:
    now = datetime.now(timezone.utc).isoformat()
    stale = (datetime.now(timezone.utc) - timedelta(hours=7)).isoformat()
    readings = iter([
        {'claude': {'used_percent': 10, 'observed_at_utc': now},
         'codex': None if initial is None else {'used_percent': 80, 'observed_at_utc': stale}},
        {'claude': {'used_percent': 12, 'observed_at_utc': now}, 'codex': {'used_percent': 20, 'observed_at_utc': now}},
        {'claude': {'used_percent': 15, 'observed_at_utc': now}, 'codex': {'used_percent': 25, 'observed_at_utc': now}},
        {'claude': {'used_percent': 15, 'observed_at_utc': now}, 'codex': {'used_percent': 25.1, 'observed_at_utc': now}},
    ])
    spend = engine.ComparisonSpend(lambda: next(readings), {})
    assert spend.fallback and spend.baselines['codex'] is None
    spend.calls = 450
    spend.check()  # Acquire before checking the call cap at the task boundary.
    assert not spend.fallback
    assert spend.baselines['codex']['used_percent'] == 20
    assert spend.baselines['codex']['observed_at_utc'] == now
    spend.calls = 451
    spend.check()  # Exactly five points passes, and the old call cap no longer applies.
    with pytest.raises(engine.SpendHalted, match='codex weekly use moved'):
        spend.check()
    assert [r['rule'] for r in spend.figures()['rules_in_force']] == ['weekly_points_and_call_cap', 'weekly_points']


def test_vendor_with_baseline_stops_while_other_baseline_missing() -> None:
    readings = iter([{'claude': {'used_percent': 10}, 'codex': None},
                     {'claude': {'used_percent': 15.1}, 'codex': None}])
    spend = engine.ComparisonSpend(lambda: next(readings), {})
    with pytest.raises(engine.SpendHalted, match='claude weekly use moved'):
        spend.check()
    assert spend.fallback


def test_comparison_recovers_baseline_and_completes_above_call_cap(tmp_path: Path) -> None:
    boundaries = 0
    now = datetime.now(timezone.utc).isoformat()
    def check() -> dict:
        nonlocal boundaries
        boundaries += 1
        return {'claude': {'used_percent': 10, 'observed_at_utc': now},
                'codex': None if boundaries <= 2 else {'used_percent': 20, 'observed_at_utc': now}}
    result = run(tmp_path, job='fast', ranked=False, count=25, spend_check=check)
    assert not result.get('halted', False) and result['spend']['model_calls'] == 225
    recorded = json.loads(Path(result['report_paths']['json']).read_text())['spend']
    assert recorded['baselines']['codex']['model_calls'] == 3
    assert recorded['baselines']['codex']['observed_at_utc'] == now
    assert recorded['baselines']['codex']['acquired_at_utc']
    assert [r['rule'] for r in recorded['rules_in_force']] == ['weekly_points_and_call_cap', 'weekly_points']
    assert 'Comparison spend:' in Path(result['report_paths']['markdown']).read_text()


def test_named_staleness_limit() -> None:
    observed = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    spend = engine.ComparisonSpend(lambda: {'claude': {'used_percent': 1, 'observed_at_utc': observed},
        'codex': {'used_percent': 1}}, {'spend_reading_stale_hours': 1})
    assert spend.baselines['claude'] is None and spend.figures()['reading_stale_hours'] == 1


@pytest.mark.parametrize('nested', [False, True])
def test_discrimination_ignores_halted_history(tmp_path: Path, nested: bool) -> None:
    table = {'tasks': [{'task_id': 'private-task', 'private': True, 'reps': ['pass'] * 3}]}
    previous = {'job': 'coder', 'tier': 'standard', 'candidate': table, 'incumbent': table}
    report = {'tiers': [dict(previous, halted=True)]} if nested else dict(previous, halted=True)
    folder = tmp_path / 'runs/old'; folder.mkdir(parents=True)
    (folder / 'report.json').write_text(json.dumps(report))
    assert engine.discrimination([table, table], tmp_path, 'coder', 'standard', 'new') == ([], [])
    (folder / 'report.json').write_text(json.dumps(previous))
    assert engine.discrimination([table, table], tmp_path, 'coder', 'standard', 'new')[1] == [
        {'task_id': 'private-task', 'run_ids': ['old', 'new']}]


def test_evenly_split_actual_wins_supply_decided_evidence() -> None:
    assert engine.quality_decided({'verdict': 'no_difference', 'tasks': [
        {'candidate_wins': 1, 'incumbent_wins': 1, 'reps': []}]})
    assert not engine.quality_decided({'verdict': 'no_difference', 'tasks': [
        {'candidate_wins': 0, 'incumbent_wins': 0, 'reps': [{'judges': [
            {'reply': 'A'}, {'reply': 'B'}]}]}]})


def test_runner_multi_job_continues_after_halt(tmp_path: Path) -> None:
    runner = (BENCH / 'run-bench.ps1').as_posix().replace("'", "''")
    script = tmp_path / 'multi-job.ps1'
    script.write_text(f"""$env:M04_FAKE_CALLS='0'
& '{runner}' -Jobs fast,writer -StateDir '{tmp_path.as_posix()}/state' -Json -NoAlerts -CliInvoker {{param($r) $env:M04_FAKE_CALLS=[string]([int]$env:M04_FAKE_CALLS+1); @{{status='ok';answer='synthetic';resolved_model=$r.model}}}} -Limits {{param($v) @{{blocked=$false;used_percent=$(if([int]$env:M04_FAKE_CALLS -ge 3){{15.1}}else{{10}})}}}}
""", encoding='utf-8')
    captured = subprocess.run(['pwsh', '-NoProfile', '-File', str(script)], capture_output=True, timeout=90)
    assert captured.returncode == 0, captured.stderr.decode('utf-8', errors='replace')[-3000:]
    reports = json.loads(captured.stdout.decode('utf-8', errors='strict'))
    assert len(reports) == 2 and reports[0]['job'] == 'fast' and reports[0]['halted']
    assert reports[1]['job'] == 'writer' and not reports[1].get('halted', False)
    assert not (tmp_path / 'state/tie-proposals').exists()
    assert not (tmp_path / 'state/effort-proposals').exists()
    assert_no_oauth_usage(tmp_path)


def test_runner_stdout_strict_utf8_roundtrip(tmp_path: Path) -> None:
    # Invoke the real host/engine transport in a fresh pwsh whose initial output
    # code page is deliberately legacy. The fake answer includes every class.
    script = tmp_path / 'fake-run.ps1'
    text = 'caf\u00e9 \u2014 \u6f22 \U0001f600'
    runner = (BENCH / 'run-bench.ps1').as_posix().replace("'", "''")
    script.write_text(f"""[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(1252)
$env:DT_MODEL_ROUTER_STATE='{tmp_path.as_posix()}/state'
& '{runner}' -Jobs fast -Models gpt-6-luna -StateDir $env:DT_MODEL_ROUTER_STATE -Json -NoAlerts -CliInvoker {{param($r) @{{status='ok';answer='{text}';resolved_model=$r.model}}}} -Limits {{param($v) @{{blocked=$false;used_percent=12}}}}
""", encoding='utf-8')
    captured = subprocess.run(['pwsh', '-NoProfile', '-File', str(script)], capture_output=True, timeout=60)
    assert captured.returncode == 0, captured.stderr.decode('utf-8', errors='replace')[-3000:]
    decoded = captured.stdout.decode('utf-8', errors='strict')
    document = json.loads(decoded)
    assert document['calls'][0]['answer'] == text
    assert decoded.encode('utf-8') == captured.stdout
    assert_no_oauth_usage(tmp_path)


def assert_no_oauth_usage(root: Path) -> None:
    assert all(json.loads(p.read_text())['source'] != 'oauth-usage' for p in root.rglob('claude-usage.json'))


def test_dot_source_preserves_console_encoding(tmp_path: Path) -> None:
    runner = (BENCH / 'run-bench.ps1').as_posix().replace("'", "''")
    script = tmp_path / 'dot-source.ps1'
    script.write_text(f"[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(1252)\n. '{runner}'\nif([Console]::OutputEncoding.CodePage -ne 1252){{throw 'console changed'}}\n")
    captured = subprocess.run(['pwsh', '-NoProfile', '-File', str(script)], capture_output=True, timeout=30)
    assert captured.returncode == 0, captured.stderr.decode(errors='replace')[-2000:]
    assert_no_oauth_usage(tmp_path)


def test_spend_lost_reading_reapplies_call_cap_from_loss() -> None:
    fresh = {'claude': {'used_percent': 10}, 'codex': {'used_percent': 10}}
    lost = {'claude': {'measurement': 'unavailable'}, 'codex': {'used_percent': 10}}
    readings = iter([fresh, lost, lost])
    spend = engine.ComparisonSpend(lambda: next(readings), {'spend_stop_model_calls': 4})
    assert not spend.fallback
    spend.calls = 100
    spend.check()  # Claude reading lost: the cap counts calls from here.
    assert spend.fallback and spend.uncovered_since == 100
    spend.calls = 104
    with pytest.raises(engine.SpendHalted, match='4/4'):
        spend.check()
    assert [r['rule'] for r in spend.figures()['rules_in_force']] == ['weekly_points', 'weekly_points_and_call_cap']


def test_spend_weekly_reset_takes_new_baseline() -> None:
    readings = iter([{'claude': {'used_percent': 80}, 'codex': {'used_percent': 10}},
                     {'claude': {'used_percent': 0}, 'codex': {'used_percent': 10}},
                     {'claude': {'used_percent': 5}, 'codex': {'used_percent': 10}},
                     {'claude': {'used_percent': 5.1}, 'codex': {'used_percent': 10}}])
    spend = engine.ComparisonSpend(lambda: next(readings), {})
    spend.check()
    assert spend.baselines['claude']['used_percent'] == 0 and not spend.fallback
    spend.check()  # Exactly five points after the reset passes.
    with pytest.raises(engine.SpendHalted, match='claude weekly use moved'):
        spend.check()
