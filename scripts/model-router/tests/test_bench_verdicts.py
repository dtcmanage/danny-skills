from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess

import pytest

from test_bench_runner import BENCH, engine, prompt_rubric, run, writer_judges


def task_subset(tmp_path: Path, names: list[str], job: str) -> Path:
    tasks = tmp_path / 'tasks'
    for name in names:
        target = tasks / name
        shutil.copytree(BENCH / 'tasks' / name, target)
        metadata = json.loads((target / 'task.json').read_text())
        metadata['job'] = job
        (target / 'task.json').write_text(json.dumps(metadata))
    return tasks


def test_one_task_gate_and_effort_lane_require_equal_passes(tmp_path: Path) -> None:
    tasks = task_subset(tmp_path, ['mechanical-extract-table'], 'fast')
    result = run(tmp_path, tasks=tasks, effort='medium',
                 dispatch=lambda r: {'status': 'ok', 'answer': 'fail' if r['model'] == 'candidate' or r['effort'] == 'low' else 'pass'},
                 grade=lambda t, a: {'status': a})
    assert result['candidate']['passed'] == result['effort_down']['passed'] == 0
    assert result['incumbent']['passed'] == 1
    assert result['raw_gate'] == 'fail' and not result['effort_down_qualified']


def test_four_tasks_keep_allowance(tmp_path: Path) -> None:
    tasks = task_subset(tmp_path, ['mechanical-extract-table', 'mechanical-rename-sweep',
                                  'routine-coding-endpoint', 'complex-coding-ledger'], 'fast')
    result = run(tmp_path, tasks=tasks, effort='medium',
                 dispatch=lambda r: {'status': 'ok', 'answer': 'candidate' if r['model'] == 'candidate' or r['effort'] == 'low' else 'incumbent'},
                 grade=lambda t, a: {'status': 'fail' if a == 'candidate' and t.name == 'mechanical-extract-table' else 'pass'})
    assert result['candidate']['passed'] == result['effort_down']['passed'] == 3
    assert result['incumbent']['passed'] == 4
    assert result['raw_gate'] == 'pass' and result['effort_down_qualified']
    assert result['better'] == 'incumbent' and not result['tied']


@pytest.mark.parametrize('candidate_failures,incumbent_failures,candidate_fabs,incumbent_fabs,better', [
    (0, 2, 3, 0, 'candidate'),  # Pass count wins despite more fabrications.
    (1, 0, 0, 3, 'candidate'),  # Fabrications win despite more first failures.
    (1, 0, 0, 0, 'incumbent'),
    (0, 1, 0, 0, 'candidate'),
    (0, 0, 0, 0, None),
    (1, 1, 1, 1, None),
])
def test_quality_ordering_and_ties(tmp_path: Path, candidate_failures: int, incumbent_failures: int,
                                   candidate_fabs: int, incumbent_fabs: int, better: str | None) -> None:
    tasks = task_subset(tmp_path, ['mechanical-extract-table'], 'fast')
    seen = {'candidate': 0, 'incumbent': 0}
    failures = {'candidate': candidate_failures, 'incumbent': incumbent_failures}
    fabs = {'candidate': candidate_fabs, 'incumbent': incumbent_fabs}
    def dispatch(request: dict) -> dict:
        model = request['model']
        seen[model] += 1
        return {'status': 'ok', 'answer': json.dumps({'status': 'fail' if seen[model] <= failures[model] else 'pass',
                                                     'fabrication': seen[model] <= fabs[model]})}
    result = run(tmp_path, tasks=tasks, dispatch=dispatch, grade=lambda t, a: json.loads(a))
    assert result['fabrications'] == {'candidate': candidate_fabs, 'incumbent': incumbent_fabs}
    assert result['better'] == better and result['tied'] == (better is None)
    assert result['tier'] == 'standard'
    assert result['configurations'] == {s: {'model': s, 'effort': 'low'} for s in ('candidate', 'incumbent')}
    persisted = json.loads(Path(result['report_paths']['json']).read_text())
    assert persisted['better'] == better and persisted['tied'] == result['tied']
    assert 'price_recommendation' not in persisted
    report = Path(result['report_paths']['markdown']).read_text()
    assert report.count('Verdict:') == 1 and 'Price recommendation' not in report


def test_unknown_never_ties_or_selects_better(tmp_path: Path) -> None:
    result = run(tmp_path, limits=lambda v: {'blocked': True})
    assert not result['tied'] and result['better'] is None


def test_recovered_first_attempt_breaks_tie(tmp_path: Path) -> None:
    tasks = task_subset(tmp_path, ['mechanical-extract-table'], 'fast')
    calls = 0
    def dispatch(request: dict) -> dict:
        nonlocal calls
        calls += 1
        return {'status': 'unknown'} if calls == 1 else {'status': 'ok', 'answer': '{}'}
    result = run(tmp_path, tasks=tasks, dispatch=dispatch)
    assert result['candidate']['passed'] == result['incumbent']['passed'] == 1
    assert result['better'] == 'incumbent' and not result['tied']


def test_recovered_judge_failure_is_not_an_answer_model_failure(tmp_path: Path) -> None:
    failed = False
    def dispatch(request: dict) -> dict:
        nonlocal failed
        if request['purpose'] == 'judge' and not failed:
            failed = True
            return {'status': 'unknown'}
        return writer_judges(request)
    result = run(tmp_path, job='writer', effort='medium', dispatch=dispatch)
    assert result['tied'] and result['better'] is None


@pytest.mark.parametrize('base,up,qualified', [(5, 5, False), (5, 4, False), (4, 5, True), (3, 4, True), (3, 3, False)])
def test_writer_effort_up_requires_strict_improvement(tmp_path: Path, base: int, up: int, qualified: bool) -> None:
    active_effort = None
    def dispatch(request: dict) -> dict:
        nonlocal active_effort
        if request['purpose'] == 'answer':
            active_effort = request['effort']
            return writer_judges(request)
        count = up if active_effort == 'high' else base
        return {'status': 'ok', 'answer': json.dumps({'scores': {line['id']: int(i < count) for i, line in enumerate(prompt_rubric(request)['lines'])}})}
    result = run(tmp_path, job='writer', effort='medium', dispatch=dispatch)
    assert result['effort_down'] is None and not result['effort_down_qualified']
    assert result['effort_up']['effort'] == 'high'
    assert result['effort_up_qualified'] == qualified
    assert all(r['side'] != 'effort-down' for r in result['outcomes'])
    assert result['tied']  # Higher effort cannot contaminate the main verdict.


@pytest.mark.parametrize('effort,next_effort', [('low', 'medium'), ('high', 'xhigh'), ('xhigh', None)])
def test_writer_effort_levels(tmp_path: Path, effort: str, next_effort: str | None) -> None:
    result = run(tmp_path, job='writer', effort=effort, dispatch=writer_judges)
    assert (result['effort_up']['effort'] if result['effort_up'] else None) == next_effort
    assert not result['effort_up_qualified'] and result['effort_down'] is None


def test_unknown_writer_effort_up_does_not_qualify(tmp_path: Path) -> None:
    result = run(tmp_path, job='writer', effort='medium',
                 dispatch=lambda r: {'status': 'unknown'} if r['purpose'] == 'answer' and r['effort'] == 'high' else writer_judges(r))
    assert not result['effort_up_qualified']


def test_other_jobs_have_no_effort_up(tmp_path: Path) -> None:
    result = run(tmp_path, effort='medium')
    assert result['effort_up'] is None and not result['effort_up_qualified']


def test_writer_never_files_effort_down_proposal(tmp_path: Path) -> None:
    script = tmp_path / 'proposal.ps1'
    builder = BENCH.parent / 'build-roster.ps1'
    script.write_text(f". '{builder.as_posix()}'\n"
                      "function Read-RouterRoster { throw 'writer effort-down must return before reading roster' }\n"
                      "Save-RouterEffortProposal ([pscustomobject]@{job='writer';effort='medium'}) "
                      "([pscustomobject]@{shadow=$false;raw_gate='pass';effort_down_qualified=$true})\n")
    process = subprocess.run(['pwsh', '-NoProfile', '-File', str(script)], capture_output=True, timeout=30)
    assert process.returncode == 0, process.stderr.decode()


@pytest.mark.parametrize('qualified', [False, True])
def test_writer_files_only_qualified_effort_up(tmp_path: Path, qualified: bool) -> None:
    result = run(tmp_path / 'bench-state', job='writer', effort='medium', dispatch=writer_judges)
    # Filing consumes the bench qualification; score computation is covered above.
    result['shadow'] = False
    result['effort_up_qualified'] = qualified
    payload = tmp_path / 'result.json'
    payload.write_text(json.dumps(result))
    script = tmp_path / 'proposal.ps1'
    script.write_text(f". '{(BENCH.parent / 'build-roster.ps1').as_posix()}'\n"
                      "function Read-RouterRoster { [pscustomobject]@{roster=@{jobs=@{writer=@{first='incumbent';first_effort='medium'}}}} }\n"
                      f"function Get-RouterStateDir {{ '{tmp_path.as_posix()}' }}\n"
                      "function New-RouterBenchProposalEvidence { @{fixture=$true} }\n"
                      "function Get-RouterBenchProposalEvidenceError { $null }\n"
                      f"$bench=Get-Content -Raw '{payload.as_posix()}' | ConvertFrom-Json -Depth 40\n"
                      "Save-RouterEffortProposal ([pscustomobject]@{job='writer';incumbent='incumbent';effort='medium'}) $bench\n")
    process = subprocess.run(['pwsh', '-NoProfile', '-File', str(script)], capture_output=True, timeout=30)
    assert process.returncode == 0, process.stderr.decode()
    proposal = tmp_path / 'effort-proposals/writer.json'
    assert proposal.exists() == qualified
    if qualified:
        stored = json.loads(proposal.read_text())
        assert stored['type'] == 'effort-swap' and stored['proposed_effort'] == 'high'
        assert 'effort_up' in stored and 'effort_down' not in stored
