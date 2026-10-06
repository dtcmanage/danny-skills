from __future__ import annotations

from copy import deepcopy
import importlib.util
import json
import shutil
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).resolve().parents[3]
BENCH = ROOT / 'scripts/model-router/bench'
sys.path.insert(0, str(BENCH))
import bench_engine as engine


def roster(job: str) -> dict:
    data = json.loads((ROOT / 'references/model-router/default-roster.json').read_text())
    data['approved'] = True
    data['approved_at'] = '2026-10-04T12:00:00Z'
    return data


def run(state: Path, *, job: str = 'coder', grade=None, dispatch=None, entry=None,
        approved: bool = False, incumbent: str | None = None, tasks: Path = BENCH / 'tasks',
        override: str | None = None) -> dict:
    state.mkdir(exist_ok=True)
    data = roster(job)
    if entry is not None:
        data['jobs'][job] = entry
    entry = data['jobs'][job]
    (state / 'roster.json').write_text(json.dumps(data))
    if approved:
        review = engine.Review(tasks, state / 'bench')
        digest = engine.bank_hash(tasks)
        for task in review.ids:
            assert review.choose(task, 'approved', digest)
    return engine.run_bench(job=job, candidate=entry['backup'], incumbent=incumbent or entry['first'],
        trigger='manual', effort=override or entry['first_effort'], effort_override=override is not None, state_dir=state, tasks=tasks,
        config=json.loads((BENCH / 'bench-config.json').read_text()),
        dispatch=dispatch or (lambda request: {'status': 'ok', 'answer': '{}'}),
        limits=lambda vendor: {'blocked': False}, envelope=lambda answer: answer,
        outcome=lambda row: None, grade=grade or (lambda task, answer: {'status': 'pass'}))


@pytest.mark.parametrize('job', ['coder', 'deep-thinker'])
def test_tier_efforts_reports_and_beyond_never_gates(tmp_path: Path, job: str, monkeypatch):
    tasks = tmp_path / 'tasks'
    shutil.copytree(BENCH / 'tasks', tasks, ignore=shutil.ignore_patterns('node_modules', '__pycache__', '*.pyc'))
    shutil.rmtree(tasks / 'pelican')
    source = 'coder-hard-schedule' if job == 'coder' else 'reasoning-hard-allocation'
    synthetic = tasks / 'synthetic-beyond'
    shutil.copytree(tasks / source, synthetic)
    metadata = json.loads((synthetic / 'task.json').read_text())
    metadata.update(id='synthetic-beyond', difficulty='beyond')
    (synthetic / 'task.json').write_text(json.dumps(metadata))
    monkeypatch.setitem(engine.CANDIDATE_INPUTS, 'synthetic-beyond', ('input.json',))
    def grade(task, answer):
        difficulty = json.loads((task / 'task.json').read_text())['difficulty']
        return {'status': 'fail' if difficulty == 'beyond' else 'pass'}
    def dispatch(request):
        if request['purpose'] == 'judge':
            # Ranked judges see identical outputs: a decided no_difference, which a tie now needs.
            if request['prompt'].startswith('The criteria below are the only instructions'):
                return {'status': 'ok', 'answer': 'no_difference'}
            rubric = next(json.loads(line) for line in request['prompt'].splitlines()
                          if line.startswith('{"threshold"'))
            return {'status': 'ok', 'answer': json.dumps({'scores': {line['id']: 1 for line in rubric['lines']}})}
        return {'status': 'ok', 'answer': '{}'}
    result = run(tmp_path, job=job, grade=grade, dispatch=dispatch, approved=True, tasks=tasks)
    assert result['gate'] == 'pass'
    assert [tier['tier'] for tier in result['tiers']] == ['standard', 'hard']
    for tier in result['tiers']:
        assert tier['tied'] and tier['better'] is None
        assert tier['candidate']['effort'] == tier['incumbent']['effort'] == ('medium' if tier['tier'] == 'standard' else 'high')
        assert all(row['tier'] == tier['tier'] for row in tier['outcomes'])
    assert result['beyond']['gate'] == 'advisory'
    assert result['beyond']['candidate']['passed'] == 0
    assert result['beyond']['candidate']['effort'] == 'high'
    assert not result['beyond']['tied'] and result['beyond']['effort_down'] is None
    assert len(list((tmp_path / 'tie-proposals').glob('*.json'))) == 2
    assert {json.loads(path.read_text())['tier'] for path in (tmp_path / 'tie-proposals').glob('*.json')} == {'standard', 'hard'}
    report = json.loads(Path(result['report_paths']['json']).read_text())
    assert len(report['tiers']) == 2 and report['beyond']['tier'] == 'beyond'


def test_per_model_and_legacy_efforts(tmp_path: Path):
    entry = roster('coder')['jobs']['coder']
    entry['backup_efforts'] = {'standard': 'low', 'hard': 'medium'}
    entry['backup_effort'] = 'low'
    result = run(tmp_path / 'tiered', entry=entry)
    assert [tier['candidate']['effort'] for tier in result['tiers']] == ['low', 'medium']
    for slot in ('first', 'backup'):
        entry.pop(slot + '_efforts')
    entry['first_effort'] = 'high'
    result = run(tmp_path / 'old', entry=entry)
    assert all(tier['incumbent']['effort'] == 'high' for tier in result['tiers'])
    assert all(tier['candidate']['effort'] == 'low' for tier in result['tiers'])


@pytest.mark.parametrize('standard_passes,hard_passes,proposed', [(2, 3, 'standard'), (1, 1, 'beyond'), (1, 2, None)])
def test_relabel_uses_first_choice_three_reps_and_never_writes_bank(tmp_path: Path, standard_passes: int, hard_passes: int, proposed: str | None):
    entry = roster('coder')['jobs']['coder']
    first = entry['first']
    counts = {}
    before = engine.bank_hash(BENCH / 'tasks')
    def dispatch(request):
        if 'minimum_slots' not in request['prompt']:
            return {'status': 'ok', 'answer': 'pass'}
        key = (request['model'], request['effort'])
        rep = counts.get(key, 0)
        counts[key] = rep + 1
        allowed = (standard_passes if request['effort'] == 'medium' else hard_passes) if request['model'] == first else 3
        return {'status': 'ok', 'answer': 'pass' if rep < allowed else 'fail'}
    result = run(tmp_path, dispatch=dispatch, grade=lambda task, answer: {'status': answer})
    assert counts[(first, 'medium')] == counts[(first, 'high')] == 3
    assert engine.bank_hash(BENCH / 'tasks') == before
    relabels = result['proposed_relabels']
    if proposed is None:
        assert not relabels
    else:
        assert relabels == [{'task_id': 'coder-hard-schedule', 'current': 'hard', 'proposed': proposed,
                            'model': first, 'standard_effort': 'medium', 'hard_effort': 'high',
                            'standard_passes': standard_passes, 'hard_passes': hard_passes}]


@pytest.mark.parametrize('protected', ['grounding-absent-answer', 'coder-hard-schedule'])
def test_effort_down_cannot_trade_protected_task_for_allowance(protected: str):
    tasks = [{'task_id': protected, 'status': 'pass'}] + [
        {'task_id': f'ordinary-{i}', 'status': 'pass'} for i in range(3)]
    incumbent = {'tasks': tasks, 'passed': 4, 'unknown': 0}
    down = deepcopy(incumbent)
    down['tasks'][0]['status'] = 'fail'
    down['passed'] = 3
    assert engine.compare(down, incumbent) == 'pass'
    assert not engine.effort_down_qualifies(down, incumbent, {protected})
    assert engine.effort_down_qualifies(down, incumbent, set())


def test_hard_effort_down_guard_in_real_tier_run(tmp_path: Path):
    def dispatch(request):
        answer = 'fail' if 'minimum_slots' in request['prompt'] and request['effort'] == 'medium' else 'pass'
        return {'status': 'ok', 'answer': answer}
    result = run(tmp_path, dispatch=dispatch, grade=lambda task, answer: {'status': answer})
    assert not result['tiers'][1]['effort_down_qualified']


def test_better_is_separate_and_conflicting_winners_do_not_propose_swap(tmp_path: Path):
    entry = roster('coder')['jobs']['coder']
    def dispatch(request):
        is_hard = 'minimum_slots' in request['prompt']
        passing = entry['backup'] if is_hard else entry['first']
        return {'status': 'ok', 'answer': 'pass' if request['model'] == passing else 'fail'}
    result = run(tmp_path, dispatch=dispatch, grade=lambda task, answer: {'status': answer})
    assert [tier['better'] for tier in result['tiers']] == [entry['first'], entry['backup']]
    assert all(not tier['tied'] for tier in result['tiers'])
    assert result['better'] is None and not result['tied']


def test_new_bank_tasks_metadata_and_outer_graders():
    for task_id in ('reasoning-hard-allocation', 'coder-hard-schedule'):
        task = BENCH / 'tasks' / task_id
        metadata = json.loads((task / 'task.json').read_text())
        assert metadata['calibration'] == 'provisional'
        assert metadata['difficulty'] == ('hard' if '-hard-' in task_id else 'beyond')
        for name, status in [('known-good.txt', 'pass'), ('known-bad.txt', 'fail')]:
            assert engine.grade_answer(task, (task / name).read_text())['status'] == status
    # Ranked tasks carry a tiers list in place of a difficulty.
    others = [json.loads(path.read_text()) for path in (BENCH / 'tasks').glob('*/task.json')
              if '-hard-' not in path.parent.name and '-beyond-' not in path.parent.name]
    assert all(metadata['difficulty'] == 'standard' for metadata in others if metadata['grader'] != 'ranked')
    assert all('difficulty' not in metadata and metadata['tiers'] for metadata in others if metadata['grader'] == 'ranked')


def test_cost_report_provenance_split_and_pending_ties(tmp_path: Path):
    spec = importlib.util.spec_from_file_location('tier_cost_report', ROOT / 'scripts/model-router/cost_report.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    rows = []
    for index, (difficulty, workstation, preflight) in enumerate([
        ('standard', 'Skill Creation', False), ('hard', 'Skill Creation', False),
        ('hard', 'Finance HQ', False), ('hard', 'Finance HQ', True), (None, 'Finance HQ', False)]):
        path = tmp_path / f'{index}.provenance.json'
        path.write_text(json.dumps({'difficulty': difficulty, 'workstation': workstation,
            'preflight': preflight, 'dispatched_at_utc': '2026-10-04T03:00:00Z'}))
        rows.append({'provenance_path': str(path)})
    (tmp_path / 'outcomes.jsonl').write_text('\n'.join(json.dumps(row) for row in rows + rows))
    split = module.difficulty_split(module.difficulty_dispatches(tmp_path), 2026, 40)
    assert split == [{'workstation': 'Finance HQ', 'standard': 0, 'hard': 1},
                     {'workstation': 'Skill Creation', 'standard': 1, 'hard': 1}]
    tables = module.routing_tables({'difficulty_dispatches': split})
    assert tables[-1][2] == [['Finance HQ', '0', '1'], ['Skill Creation', '1', '1']]
    reports = module.build_weekly_reports([], [], {}, dispatch_rows=module.difficulty_dispatches(tmp_path))
    assert len(reports) == 1 and reports[0]['difficulty_dispatches'] == split
    directory = tmp_path / 'tie-proposals'
    directory.mkdir()
    for name, status in [('coder', 'pending'), ('coder-hard', 'pending'), ('writer', 'declined')]:
        (directory / f'{name}.json').write_text(json.dumps({'status': status}))
    lines = module.compute_needs_you_lines(tmp_path)
    assert any("2 tie proposal(s) pending Danny's OK" in line for line in lines)


@pytest.mark.parametrize('job', ['fast', 'writer', 'coder', 'deep-thinker'])
def test_explicit_override_controls_both_slots_and_writer_up(tmp_path: Path, job: str):
    entry = roster(job)['jobs'][job]
    result = run(tmp_path, job=job, entry=entry, override='high')
    for tier in result.get('tiers', [result]):
        assert tier['candidate']['effort'] == tier['incumbent']['effort'] == 'high'
        assert not tier['proposed_relabels']
    if job == 'writer':
        assert result['effort_up']['effort'] == 'xhigh'


def test_equal_tier_efforts_skip_calibration_and_relabels(tmp_path: Path):
    entry = roster('coder')['jobs']['coder']
    entry['first_efforts']['hard'] = 'medium'
    counts = {}
    def dispatch(request):
        if 'minimum_slots' in request['prompt']:
            key = (request['model'], request['effort'])
            counts[key] = counts.get(key, 0) + 1
        return {'status': 'ok', 'answer': '{}'}
    result = run(tmp_path, entry=entry, dispatch=dispatch)
    assert not result['proposed_relabels']
    assert counts[(entry['first'], 'medium')] == 3


def test_allocation_rejects_json_booleans_and_defines_agent_to_slot():
    task = BENCH / 'tasks/reasoning-hard-allocation'
    result = json.loads((task / 'known-good.txt').read_text())
    assert 'a_i is the slot assigned to agent i' in (task / 'prompt.md').read_text()
    for field in ('assignment', 'cost'):
        bad = deepcopy(result)
        if field == 'assignment':
            bad[field] = [bool(value) if value in (0, 1) else value for value in bad[field]]
        else:
            bad[field] = True
        assert engine.grade_answer(task, json.dumps(bad))['status'] == 'fail'


@pytest.mark.parametrize('heavy', [False, True])
def test_schedule_grader_rejects_greedy_and_accepts_known_good(heavy: bool):
    task = BENCH / 'tasks/coder-hard-schedule'
    answer = '''
def minimum_slots(jobs, capacity):
    done, slots = set(), 0
    while len(done) < len(jobs):
        ready = [job for job in jobs if job['id'] not in done and set(job['deps']) <= done]
        if HEAVY:
            ready.sort(key=lambda job: -job['weight'])
        chosen, weight = [], 0
        for job in ready:
            if weight + job['weight'] <= capacity:
                chosen.append(job['id'])
                weight += job['weight']
        if not chosen:
            return None
        done.update(chosen)
        slots += 1
    return slots
'''.replace('HEAVY', repr(heavy))
    assert engine.grade_answer(task, answer)['status'] == 'fail'
    assert engine.grade_answer(task, (task / 'known-good.txt').read_text())['status'] == 'pass'
