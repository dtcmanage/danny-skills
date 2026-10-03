from pathlib import Path
import json
import sys

import pytest

from test_bench_runner import run
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cost_report


@pytest.mark.parametrize('job,effort', [('fast', 'low'), ('coder', 'medium'), ('deep-thinker', 'high'), ('writer', 'medium')])
def test_unknown_blocks_shadow(tmp_path: Path, job: str, effort: str) -> None:
    calls = []
    result = run(tmp_path, job=job, effort=effort, limits=lambda vendor: {'blocked': True},
                 dispatch=lambda request: calls.append(request))
    assert result['shadow'] and result['gate'] == 'unknown'
    assert not calls


def test_pending_effort_only(tmp_path: Path) -> None:
    jobs = {job: {'first': 'candidate', 'backup': 'incumbent', 'first_effort': 'medium', 'backup_effort': 'medium'}
            for job in cost_report.ROUTER_JOBS}
    live = {'approved': True, 'jobs': jobs}
    (tmp_path / 'roster.json').write_text(json.dumps(live))
    proposal = json.loads(json.dumps(live))
    proposal['jobs']['coder']['first_effort'] = 'low'
    path = tmp_path / 'proposal.json'
    path.write_text(json.dumps(proposal))
    directory = tmp_path / 'roster-proposals'
    directory.mkdir()
    (directory / 'latest.json').write_text(json.dumps({'proposal': str(path)}))
    assert cost_report.compute_pending_roster_proposal(tmp_path)
    (tmp_path / 'roster.json').write_text(json.dumps(proposal))
    assert not cost_report.compute_pending_roster_proposal(tmp_path)


def test_weekly_effort_identity_and_disagreement(tmp_path: Path) -> None:
    jobs = {'coder': {'first': 'model', 'first_effort': 'medium'}}
    (tmp_path / 'roster.json').write_text(json.dumps({'jobs': jobs}))
    directory = tmp_path / 'effort-proposals'
    directory.mkdir()
    swap = {'status': 'pending', 'job': 'coder', 'model': 'model',
            'current_effort': 'medium', 'proposed_effort': 'low'}
    (directory / 'coder.json').write_text(json.dumps(swap))
    (tmp_path / 'outcomes.jsonl').write_text(json.dumps({'source': 'bench', 'disagreement': True, 'task_bank_sha256': __import__('review').bank_hash(cost_report.REPO_ROOT / 'scripts/model-router/bench/tasks'), 'judge_models': ['claude-fable-5-1', 'gpt-6-astra']}) + '\n')
    lines = cost_report.compute_needs_you_lines(tmp_path)
    assert any('effort swap for coder' in line for line in lines)
    assert any('1 bench judge disagreements' in line for line in lines)
    assert any('golden review' in line for line in lines)
    jobs['coder']['first_effort'] = 'low'
    (tmp_path / 'roster.json').write_text(json.dumps({'jobs': jobs}))
    assert not any('effort swap' in line for line in cost_report.compute_needs_you_lines(tmp_path))


def test_disagreement_ignores_retired_bank_and_judges(tmp_path: Path) -> None:
    import review
    digest = review.bank_hash(cost_report.REPO_ROOT / 'scripts/model-router/bench/tasks')
    rows = [dict(source='bench', disagreement=True, task_bank_sha256='old', judge_models=['claude-fable-5-1', 'gpt-6-astra']),
            dict(source='bench', disagreement=True, task_bank_sha256=digest, judge_models=['old-judge', 'gpt-6-astra'])]
    (tmp_path / 'outcomes.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
    assert not any('judge disagreements' in line for line in cost_report.compute_needs_you_lines(tmp_path))
