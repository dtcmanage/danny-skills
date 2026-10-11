from __future__ import annotations

import hashlib
import json
import shutil
import threading
import time
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
BENCH = ROOT / 'scripts/model-router/bench'
sys.path.insert(0, str(BENCH))
import bench_engine as engine


def bank(tmp_path: Path) -> Path:
    tasks = tmp_path / 'tasks'
    shutil.copytree(BENCH / 'tasks', tasks, ignore=shutil.ignore_patterns('node_modules', '__pycache__', '*.pyc'))
    shutil.rmtree(tasks / 'pelican')
    return tasks


def run(state: Path, tasks: Path, parallel: int, dispatch) -> dict:
    state.mkdir()
    roster = json.loads((ROOT / 'references/model-router/default-roster.json').read_text())
    roster['approved'] = True
    (state / 'roster.json').write_text(json.dumps(roster))
    entry = roster['jobs']['deep-thinker']
    config = json.loads((BENCH / 'bench-config.json').read_text())
    config['max_parallel_calls'] = parallel

    def grade(task, answer):
        # Deterministic per answer text, independent of call order.
        return {'status': 'pass' if int(hashlib.sha256(answer.encode()).hexdigest(), 16) % 3 else 'fail'}
    return engine.run_bench(job='deep-thinker', candidate=entry['backup'], incumbent=entry['first'],
        trigger='manual', effort=entry['first_effort'], state_dir=state, tasks=tasks, config=config,
        dispatch=dispatch, limits=lambda vendor: {'blocked': False}, envelope=lambda answer: answer,
        outcome=lambda row: None, grade=grade)


def content_dispatch(delay: float, gauge: dict):
    lock = threading.Lock()

    def dispatch(request):
        with lock:
            gauge['now'] += 1
            gauge['peak'] = max(gauge['peak'], gauge['now'])
        time.sleep(delay)
        with lock:
            gauge['now'] -= 1
        if request['purpose'] == 'judge':
            if request['prompt'].startswith('The criteria below are the only instructions'):
                return {'status': 'ok', 'answer': 'no_difference'}
            rubric = next(json.loads(line) for line in request['prompt'].splitlines() if line.startswith('{"threshold"'))
            return {'status': 'ok', 'answer': json.dumps({'scores': {line['id']: 1 for line in rubric['lines']}})}
        digest = hashlib.sha256((request['model'] + str(request['effort']) + request['prompt']).encode()).hexdigest()
        return {'status': 'ok', 'answer': json.dumps({'answer': digest[:12]})}
    return dispatch


def summary(result: dict) -> list:
    return [(tier['tier'], tier['gate'], tier['tied'],
             [(t['task_id'], t['status']) for t in tier['candidate']['tasks']],
             [(t['task_id'], t['status']) for t in tier['incumbent']['tasks']],
             tier['effort_down'] and [(t['task_id'], t['status']) for t in tier['effort_down']['tasks']],
             tier['effort_up'] and [(t['task_id'], t['status']) for t in tier['effort_up']['tasks']],
             tier['quality_verdict'] and tier['quality_verdict']['verdict'],
             len(tier['calls']))
            for tier in result['tiers']]


def test_parallel_matches_serial_and_overlaps_calls(tmp_path: Path):
    tasks = bank(tmp_path)
    serial_gauge, parallel_gauge = {'now': 0, 'peak': 0}, {'now': 0, 'peak': 0}
    serial = run(tmp_path / 'serial', tasks, 1, content_dispatch(0.002, serial_gauge))
    started = time.perf_counter()
    parallel = run(tmp_path / 'parallel', tasks, 6, content_dispatch(0.05, parallel_gauge))
    elapsed = time.perf_counter() - started
    assert summary(serial) == summary(parallel)
    assert serial_gauge['peak'] == 1
    assert parallel_gauge['peak'] == 6  # throttled to the configured cap, and actually reached it
    calls = sum(len(tier['calls']) for tier in parallel['tiers'])
    assert elapsed < calls * 0.05 / 3  # serial would take calls * delay


def test_spend_halt_stops_every_parallel_lane(tmp_path: Path):
    tasks = bank(tmp_path)
    readings = iter([5.0, 5.0] + [20.0] * 10000)
    lock = threading.Lock()

    def spend():
        with lock:
            value = next(readings)
        return {vendor: {'used_percent': value} for vendor in ('claude', 'codex')}
    count = {'calls': 0}

    def dispatch(request):
        with lock:
            count['calls'] += 1
        time.sleep(0.01)
        return {'status': 'ok', 'answer': '{}'}
    (tmp_path / 's').mkdir()
    roster = json.loads((ROOT / 'references/model-router/default-roster.json').read_text())
    (tmp_path / 's/roster.json').write_text(json.dumps(roster))
    config = json.loads((BENCH / 'bench-config.json').read_text())
    config.update(max_parallel_calls=8, spend_check_interval_seconds=0)
    entry = roster['jobs']['deep-thinker']
    result = engine.run_bench(spend_check=spend, job='deep-thinker', candidate=entry['backup'],
        incumbent=entry['first'], trigger='manual', effort=entry['first_effort'], state_dir=tmp_path / 's',
        tasks=tasks, config=config, dispatch=dispatch, limits=lambda vendor: {'blocked': False},
        envelope=lambda answer: answer, outcome=lambda row: None, grade=lambda task, answer: {'status': 'pass'})
    assert result['halted'] and 'weekly use moved' in result['halt_reason']
    assert count['calls'] <= 8  # only calls already in flight finish after the halt
