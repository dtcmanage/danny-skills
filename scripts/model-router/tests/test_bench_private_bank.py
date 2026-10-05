from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

BENCH = Path(__file__).resolve().parents[1] / 'bench'
sys.path.insert(0, str(BENCH))
sys.path.insert(0, str(BENCH.parent))
import add_task
import bench_engine as engine
import review


def intake(tmp_path: Path, *, task_id: str | None = None, job: str = 'fast',
           grader: str = 'exact', difficulty: str = 'standard', answer: str = '{"value": 7}') -> Path:
    problem = tmp_path / 'Synthetic Problem.md'
    expected = tmp_path / 'expected.txt'
    problem.write_text('Return the synthetic value seven.', encoding='utf-8')
    expected.write_text(answer, encoding='utf-8')
    (tmp_path / 'state').mkdir(exist_ok=True)
    return add_task.add_task(state=tmp_path / 'state', problem=problem, answer=expected,
                             job=job, grader=grader, difficulty=difficulty, task_id=task_id)


def run(tmp_path: Path, tasks: Path, *, job: str = 'fast') -> dict:
    return engine.run_bench(job=job, candidate='gpt-test', incumbent='claude-test',
        trigger='manual', effort='low', state_dir=tmp_path / 'state', tasks=tasks,
        config={'judges': {'claude': 'claude-judge', 'codex': 'gpt-judge'}, 'judge_effort': 'high'},
        dispatch=lambda request: {'status': 'ok', 'answer': '{"value": 7}'},
        limits=lambda vendor: {'blocked': False}, envelope=lambda text: text, outcome=lambda row: None,
        grade=lambda task, answer: {'status': 'pass'})


def test_baseline_fixture_and_empty_private(tmp_path: Path):
    expected = (Path(__file__).parent / 'fixtures/bench-bank-sha256.txt').read_text().strip()
    tasks = BENCH / 'tasks'
    private = tmp_path / 'private'
    assert review.bank_hash(tasks) == expected
    assert review.bank_hash(tasks, private) == expected
    private.mkdir()
    assert review.bank_hash(tasks, private) == expected


def test_private_hash_encoding_mutations_and_ignored_dirs(tmp_path: Path):
    task = intake(tmp_path)
    private = task.parent
    tasks = BENCH / 'tasks'
    original = review.bank_hash(tasks)
    combined = review.bank_hash(tasks, private)
    assert combined != original
    digest = hashlib.sha256()
    for root, prefix in ((tasks, ''), (private, 'private/')):
        for path in review.bank_files(root):
            name = (prefix + path.relative_to(root).as_posix()).encode()
            data = path.read_bytes()
            digest.update(len(name).to_bytes(8, 'big') + name)
            digest.update(len(data).to_bytes(8, 'big') + data)
    assert combined == digest.hexdigest()
    extra = task / 'extra.txt'
    extra.write_text('one')
    added = review.bank_hash(tasks, private)
    assert added != combined
    extra.write_text('two')
    assert review.bank_hash(tasks, private) not in {combined, added}
    extra.unlink()
    assert review.bank_hash(tasks, private) == combined
    for ignored in review.IGNORED:
        cache = task / ignored / 'cache.txt'
        cache.parent.mkdir()
        cache.write_text('ignored')
    assert review.bank_hash(tasks, private) == combined


def test_engine_loads_private_and_duplicate_is_error(tmp_path: Path):
    task = intake(tmp_path)
    result = run(tmp_path, BENCH / 'tasks')
    loaded = {row['task_id']: row['private'] for row in result['candidate']['tasks']}
    assert loaded[task.name] is True and loaded['mechanical-extract-table'] is False
    assert all(row['private'] for row in result['outcomes'] if row['task_id'] == task.name)
    shutil.copytree(task, task.parent / 'mechanical-extract-table')
    with pytest.raises(ValueError, match='Duplicate task id.*mechanical-extract-table'):
        run(tmp_path, BENCH / 'tasks')


def test_private_hard_task_participates_in_tier_discovery(tmp_path: Path):
    task = intake(tmp_path, job='coder', difficulty='hard')
    result = run(tmp_path, BENCH / 'tasks', job='coder')
    hard = next(tier for tier in result['tiers'] if tier['tier'] == 'hard')
    assert any(row['task_id'] == task.name and row['private'] for row in hard['candidate']['tasks'])


def approve(service: review.Review) -> dict:
    digest = service.refresh()['task_bank_sha256']
    for task_id in service.ids:
        assert service.choose(task_id, 'approved', digest)
    return service.refresh()


def test_review_marks_private_real_count_and_resets(tmp_path: Path):
    task = intake(tmp_path)
    service = review.Review(BENCH / 'tasks', tmp_path / 'state/bench')
    value = approve(service)
    assert value['approved'] and value['private_task_ids'] == [task.name]
    assert not run(tmp_path, BENCH / 'tasks')['shadow']
    html = service.render(value)
    assert f'{task.name} (private)' in html and 'All 21 approved' in html
    before = value['task_bank_sha256']
    (task / 'prompt.md').write_text('Changed synthetic request')
    assert not service.choose(task.name, 'approved', before)
    value = service.refresh()
    assert not value['approved'] and set(value['tasks'].values()) == {'pending'}


@pytest.mark.parametrize('unreadable', [False, True])
def test_unavailable_approved_private_bank_is_explained(tmp_path: Path, monkeypatch, unreadable: bool):
    task = intake(tmp_path)
    service = review.Review(BENCH / 'tasks', tmp_path / 'state/bench')
    value = approve(service)
    if unreadable:
        real = review.private_files
        def denied(path: Path) -> list[Path]:
            if path == task.parent:
                raise PermissionError('synthetic unreadable private folder')
            return real(path)
        monkeypatch.setattr(review, 'private_files', denied)
    else:
        task.parent.rename(task.parent.with_name('unavailable-bank'))
    warning = review.private_bank_warning(BENCH / 'tasks', task.parent, value)
    assert warning and 'missing or unreadable' in warning
    assert str(task.parent.resolve()) in warning and 'approval is reset' in warning
    result = run(tmp_path, BENCH / 'tasks')
    assert result['shadow'] and result['private_bank_warning'] == warning
    assert warning in Path(result['report_paths']['markdown']).read_text(encoding='utf-8')
    refreshed = service.refresh()
    assert not refreshed['approved'] and refreshed['private_task_ids'] == [task.name]
    assert warning in service.render(refreshed)
    assert warning in service.render(service.refresh())
    import cost_report
    assert warning in cost_report.compute_needs_you_lines(tmp_path / 'state')
    if unreadable:
        monkeypatch.undo()
    else:
        task.parent.with_name('unavailable-bank').rename(task.parent)
    restored = service.refresh()
    assert not restored['approved'] and not restored['private_bank_warning']
    assert set(restored['tasks'].values()) == {'pending'}


@pytest.mark.parametrize(('grader', 'answer'), [('exact', '{"value": 7}'), ('numeric', '{"value": 7}'), ('exact', 'seven')])
def test_intake_cli_loadable_and_existing_graders(tmp_path: Path, grader: str, answer: str):
    task = intake(tmp_path, grader=grader, answer=answer)
    assert task.name == 'synthetic-problem'
    assert engine.candidate_prompt(task, private=True) == 'Return the synthetic value seven.'
    assert review.task_folders(BENCH / 'tasks', task.parent)[task.name] == (task, True)
    assert engine.grade_answer(task, (task / 'known-good.txt').read_text())['status'] == 'pass'
    assert engine.grade_answer(task, '{"value": 0}')['status'] == 'fail'
    args = [sys.executable, str(BENCH / 'add_task.py'), '--state', str(tmp_path / 'state'),
            '--problem', str(tmp_path / 'Synthetic Problem.md'), '--answer', str(tmp_path / 'expected.txt'),
            '--job', 'fast', '--grader', grader, '--difficulty', 'standard']
    before = (task / 'task.json').read_bytes()
    duplicate = subprocess.run(args, capture_output=True, text=True, timeout=30)
    assert duplicate.returncode != 0 and (task / 'task.json').read_bytes() == before
    created = subprocess.run(args + ['--id', 'cli-task'], capture_output=True, text=True, timeout=30)
    assert created.returncode == 0 and (task.parent / 'cli-task/task.json').exists()


def test_intake_rejects_repo_state_and_invalid_ids(tmp_path: Path):
    task = intake(tmp_path)
    for state in (add_task.REPO / 'synthetic-state', add_task.main_checkout() / 'synthetic-state'):
        with pytest.raises(ValueError, match='outside the repo'):
            add_task.add_task(state=state, problem=task / 'prompt.md', answer=task / 'known-good.txt',
                             job='fast', grader='exact', difficulty='standard')
        assert not state.exists()
    with pytest.raises(ValueError, match='slug'):
        intake(tmp_path, task_id='../escape')


@pytest.mark.parametrize('site', ['router-common.ps1', 'build-roster.ps1'])
def test_powershell_compute_sites_match_python(tmp_path: Path, site: str):
    if not shutil.which('pwsh'):
        pytest.fail('pwsh required for the M01 parity gate')
    task = intake(tmp_path)
    script = tmp_path / 'hash-check.ps1'
    if site == 'router-common.ps1':
        body = ". (Join-Path $benchRoot '../router-common.ps1')\n(Get-RouterBenchEvidenceContext).task_bank_sha256\n"
    else:
        source = (BENCH.parent / site).read_text(encoding='utf-8')
        line = next(line.strip() for line in source.splitlines() if 'from review import bank_hash' in line)
        line = line.replace("(Join-Path $PSScriptRoot 'bench')", '$benchRoot')
        body = line + "\nif ($LASTEXITCODE -ne 0) { throw 'hash failed' }\n$digest\n"
    script.write_text("param([string]$benchRoot,[string]$state)\nSet-StrictMode -Version Latest\n"
        "$ErrorActionPreference = 'Stop'\n" + body, encoding='utf-8')
    result = subprocess.run(['pwsh', '-NoProfile', '-File', str(script), str(BENCH), str(tmp_path / 'state')],
                            env={**os.environ, 'DT_MODEL_ROUTER_STATE': str(tmp_path / 'state')},
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == review.bank_hash(BENCH / 'tasks', task.parent)


def test_missing_private_bank_can_be_reapproved(tmp_path: Path):
    task = intake(tmp_path)
    service = review.Review(BENCH / 'tasks', tmp_path / 'state/bench')
    assert approve(service)['approved']
    task.parent.rename(task.parent.with_name('unavailable-bank'))
    value = service.refresh()
    assert not value['approved'] and set(value['tasks'].values()) == {'pending'}
    assert value['private_task_ids'] == [task.name]
    value = approve(service)
    assert value['approved'] and value['private_task_ids'] == []
    assert value['private_bank_warning'] is None
    assert service.refresh()['approved']
    assert not run(tmp_path, BENCH / 'tasks')['shadow']


@pytest.mark.parametrize('task_id', ['pelican', 'mechanical-extract-table'])
def test_intake_refuses_in_repo_ids(tmp_path: Path, task_id: str):
    with pytest.raises(ValueError, match=f'Duplicate task id.*{task_id}'):
        intake(tmp_path, task_id=task_id)
    assert not (review.private_bank_path(tmp_path / 'state') / task_id).exists()


def test_intake_refuses_private_id_case_insensitively(tmp_path: Path):
    task = intake(tmp_path, task_id='existing')
    task.rename(task.with_name('Existing'))
    with pytest.raises(ValueError, match='Duplicate task id.*existing'):
        intake(tmp_path, task_id='existing')


def test_intake_refuses_in_repo_id_case_insensitively(tmp_path: Path, monkeypatch):
    tasks = tmp_path / 'in-repo'
    (tasks / 'Pelican').mkdir(parents=True)
    (tasks / 'Pelican/task.json').write_text('{}')
    monkeypatch.setattr(add_task, 'TASKS', tasks)
    with pytest.raises(ValueError, match='Duplicate task id.*pelican'):
        intake(tmp_path, task_id='pelican')


def test_intake_missing_state_and_known_good_failure_cli(tmp_path: Path):
    problem, answer = tmp_path / 'problem.md', tmp_path / 'answer.txt'
    problem.write_text('Synthetic problem')
    answer.write_text('NaN')
    state = tmp_path / 'state'
    args = [sys.executable, str(BENCH / 'add_task.py'), '--state', str(state),
            '--problem', str(problem), '--answer', str(answer), '--job', 'fast',
            '--grader', 'exact', '--difficulty', 'standard', '--id', 'nan-task']
    missing = subprocess.run(args, capture_output=True, text=True, timeout=30)
    assert missing.returncode != 0 and 'State directory does not exist' in missing.stderr
    assert not state.exists() and not review.private_bank_path(state).exists()
    state.mkdir()
    rejected = subprocess.run(args, capture_output=True, text=True, timeout=30)
    assert rejected.returncode != 0 and 'Known-good answer did not pass the exact grader' in rejected.stderr
    assert not (review.private_bank_path(state) / 'nan-task').exists()


@pytest.mark.parametrize('malformed', ['no-task-json', 'nested-task-json', 'root-task-json', 'bad-json'])
def test_engine_refuses_malformed_private_tasks(tmp_path: Path, malformed: str):
    (tmp_path / 'state').mkdir()
    private = review.private_bank_path(tmp_path / 'state')
    folder = private / 'broken'
    folder.mkdir(parents=True)
    (folder / 'prompt.md').write_text('Synthetic prompt')
    if malformed == 'nested-task-json':
        folder = folder / 'nested'
        folder.mkdir()
        (folder / 'task.json').write_text('{}')
    elif malformed == 'root-task-json':
        folder = private
        (private / 'task.json').write_text('{}')
    elif malformed == 'bad-json':
        (folder / 'task.json').write_text('{bad json')
    with pytest.raises(ValueError) as error:
        run(tmp_path, BENCH / 'tasks')
    assert str(folder) in str(error.value)
    if malformed == 'bad-json':
        assert str(folder / 'task.json') in str(error.value) and 'Invalid JSON' in str(error.value)


def test_loader_duplicate_ids_case_insensitively(tmp_path: Path):
    task = intake(tmp_path)
    shutil.copytree(task, task.parent / 'Mechanical-Extract-Table')
    with pytest.raises(ValueError, match='Duplicate task id.*Mechanical-Extract-Table'):
        run(tmp_path, BENCH / 'tasks')


def test_reserved_private_in_repo_folder_cannot_imitate_hash_domain(tmp_path: Path):
    tasks = tmp_path / 'tasks'
    (tasks / 'private/x').mkdir(parents=True)
    (tasks / 'private/x/task.json').write_text('{}')
    for operation in (review.bank_hash, review.task_folders):
        with pytest.raises(ValueError, match="In-repo task folder 'private' is reserved"):
            operation(tasks)


def test_candidate_input_fallback_only_for_private(tmp_path: Path, monkeypatch):
    task = intake(tmp_path)
    assert engine.candidate_prompt(task, private=True) == (task / 'prompt.md').read_text()
    with pytest.raises(KeyError):
        engine.candidate_prompt(task)
    monkeypatch.delitem(engine.CANDIDATE_INPUTS, 'mechanical-extract-table')
    with pytest.raises(KeyError, match='mechanical-extract-table'):
        run(tmp_path, BENCH / 'tasks')


def test_intake_grader_fallback_only_for_private_and_help(tmp_path: Path):
    task = intake(tmp_path, answer='seven')
    assert engine.grade_answer(task, '  seven\n')['status'] == 'pass'
    assert engine.grade_answer(task, 'Seven')['status'] == 'fail'
    repo_task = tmp_path / 'in-repo/task'
    shutil.copytree(task, repo_task)
    result = engine.grade_answer(repo_task, 'seven')
    assert result['status'] == 'unknown' and result['detail'] == 'Missing task grader'
    help_result = subprocess.run([sys.executable, str(BENCH / 'add_task.py'), '--help'],
                                 capture_output=True, text=True, timeout=30)
    assert help_result.returncode == 0
    assert 'whitespace-trimmed equality' in help_result.stdout


def test_sibling_location_and_old_bank_is_not_loaded(tmp_path: Path):
    task = intake(tmp_path)
    assert task.parent == tmp_path / 'bench-private-bank'
    old = tmp_path / 'state/bench/private-bank/broken'
    old.mkdir(parents=True)
    (old / 'task.json').write_text('{bad json')
    service = review.Review(BENCH / 'tasks', tmp_path / 'state/bench')
    assert task.name in service.ids and 'broken' not in service.ids
    assert run(tmp_path, BENCH / 'tasks')['task_bank_sha256'] == review.bank_hash(BENCH / 'tasks', task.parent)


@pytest.mark.parametrize('content', ['[]', '{}', '"text"'])
def test_engine_refuses_incomplete_private_task_metadata(tmp_path: Path, content: str):
    (tmp_path / 'state').mkdir()
    folder = review.private_bank_path(tmp_path / 'state') / 'broken'
    folder.mkdir(parents=True)
    (folder / 'task.json').write_text(content)
    with pytest.raises(ValueError, match='job, grader and category') as error:
        run(tmp_path, BENCH / 'tasks')
    assert str(folder / 'task.json') in str(error.value)


@pytest.mark.parametrize('content', ['[1]', '"text"', '7'])
def test_cost_report_survives_non_object_golden_approval(tmp_path: Path, content: str):
    sys.path.insert(0, str(BENCH.parent))
    import cost_report
    state = tmp_path / 'state'
    (state / 'bench').mkdir(parents=True)
    (state / 'bench/golden-approval.json').write_text(content)
    lines = cost_report.compute_needs_you_lines(state, add_task.REPO)
    assert any('golden review is waiting' in line for line in lines)


def test_intake_refuses_bench_folder_as_state(tmp_path: Path):
    bench = tmp_path / 'state' / 'bench'
    bench.mkdir(parents=True)
    problem = tmp_path / 'p.md'
    problem.write_text('Return seven.')
    with pytest.raises(ValueError, match='not its bench folder'):
        add_task.add_task(state=bench, problem=problem, answer=problem,
                          job='fast', grader='exact', difficulty='standard')
    assert not (tmp_path / 'state' / 'bench-private-bank').exists()
