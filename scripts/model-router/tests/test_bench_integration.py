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
    (tmp_path / 'outcomes.jsonl').write_text(json.dumps({'source': 'bench', 'disagreement': True, 'task_bank_sha256': __import__('review').bank_hash(cost_report.REPO_ROOT / 'scripts/model-router/bench/tasks'), 'judge_models': ['claude-fable-5-1', 'gpt-6-astra'], 'judge_effort': 'high'}) + '\n')
    lines = cost_report.compute_needs_you_lines(tmp_path)
    assert any('stale or legacy benchmark evidence' in line for line in lines)
    assert not any('-ApproveEffort' in line for line in lines)
    assert any('1 bench judge disagreements' in line for line in lines)
    assert any('golden review' in line for line in lines)
    digest = __import__('review').bank_hash(cost_report.REPO_ROOT / 'scripts/model-router/bench/tasks')
    (tmp_path / 'bench').mkdir()
    (tmp_path / 'bench/golden-approval.json').write_text(json.dumps({'approved': True, 'task_bank_sha256': digest}))
    swap['bench_evidence'] = {'task_bank_sha256': digest, 'judge_pair': None, 'judge_effort': None}
    (directory / 'coder.json').write_text(json.dumps(swap))
    assert any('effort swap for coder' in line for line in cost_report.compute_needs_you_lines(tmp_path))
    jobs['coder']['first_effort'] = 'low'
    (tmp_path / 'roster.json').write_text(json.dumps({'jobs': jobs}))
    assert not any('effort swap' in line for line in cost_report.compute_needs_you_lines(tmp_path))


def test_disagreement_ignores_retired_bank_and_judges(tmp_path: Path) -> None:
    import review
    digest = review.bank_hash(cost_report.REPO_ROOT / 'scripts/model-router/bench/tasks')
    rows = [dict(source='bench', disagreement=True, task_bank_sha256='old', judge_models=['claude-fable-5-1', 'gpt-6-astra']),
            dict(source='bench', disagreement=True, task_bank_sha256=digest, judge_models=['old-judge', 'gpt-6-astra']),
            dict(source='bench', disagreement=True, task_bank_sha256=digest,
                 judge_models=['claude-fable-5-1', 'gpt-6-astra'], judge_effort='low'),
            dict(source='bench', disagreement=True, task_bank_sha256=digest,
                 judge_models=['claude-fable-5-1', 'gpt-6-astra'])]
    (tmp_path / 'outcomes.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
    assert not any('judge disagreements' in line for line in cost_report.compute_needs_you_lines(tmp_path))


def test_legacy_judge_config_uses_shipped_effort_for_disagreements(tmp_path: Path) -> None:
    import review
    config = {"judges": {"claude": "claude-fable-5-1", "codex": "gpt-6-astra"}}
    (tmp_path / "bench").mkdir()
    (tmp_path / "bench/judge-config.json").write_text(json.dumps(config))
    digest = review.bank_hash(cost_report.REPO_ROOT / "scripts/model-router/bench/tasks")
    rows = [dict(source="bench", disagreement=True, task_bank_sha256=digest,
                 judge_models=list(config["judges"].values()), judge_effort=effort)
            for effort in ("high", "low", None)]
    (tmp_path / "outcomes.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
    assert any("1 bench judge disagreements" in line for line in cost_report.compute_needs_you_lines(tmp_path))
    assert json.loads((tmp_path / "bench/judge-config.json").read_text()) == config


@pytest.mark.parametrize('defect', ['none', 'bank', 'pair', 'effort', 'invalid-effort', 'extra-key', 'array-model', 'list-pair', 'nonobject-config', 'malformed-config', 'withdrawn'])
def test_weekly_rubric_proposals_bind_current_evidence(tmp_path: Path, defect: str) -> None:
    import review
    digest = review.bank_hash(cost_report.REPO_ROOT / 'scripts/model-router/bench/tasks')
    pair = {'claude': 'claude-fable-5-1', 'codex': 'gpt-6-astra'}
    evidence = {'task_bank_sha256': digest, 'judge_pair': pair.copy(), 'judge_effort': 'high'}
    config = {'judges': pair.copy(), 'judge_effort': 'high'}
    approved = defect != 'withdrawn'
    if defect == 'bank': evidence['task_bank_sha256'] = 'old'
    if defect == 'pair': config['judges']['claude'] = 'changed-judge'
    if defect == 'effort': config['judge_effort'] = 'medium'
    if defect == 'invalid-effort': config['judge_effort'] = ['high']
    if defect == 'extra-key': config['judges']['note'] = 'x'
    if defect == 'array-model': config['judges']['claude'] = ['claude-fable-5-1']
    if defect == 'list-pair': config['judges'] = ['claude-fable-5-1', 'gpt-6-astra']
    if defect == 'nonobject-config': config = ['invalid']
    bench = tmp_path / 'bench'
    bench.mkdir()
    (bench / 'golden-approval.json').write_text(json.dumps({'approved': approved, 'task_bank_sha256': digest}))
    (bench / 'judge-config.json').write_text('{' if defect == 'malformed-config' else json.dumps(config))
    jobs = {job: {'first': 'model', 'backup': 'backup', 'first_effort': 'medium', 'backup_effort': 'medium'}
            for job in cost_report.ROUTER_JOBS}
    (tmp_path / 'roster.json').write_text(json.dumps({'approved': True, 'jobs': jobs}))
    (tmp_path / 'effort-proposals').mkdir()
    (tmp_path / 'effort-proposals/writer.json').write_text(json.dumps({
        'status': 'pending', 'job': 'writer', 'model': 'model', 'current_effort': 'medium',
        'proposed_effort': 'low', 'bench_evidence': evidence}))
    proposed = json.loads(json.dumps(jobs))
    proposed['writer']['first'] = 'candidate'
    directory = tmp_path / 'roster-proposals'
    directory.mkdir()
    proposal_path = directory / 'test.json'
    proposal_path.write_text(json.dumps({'jobs': proposed, 'pass_id': 'test', 'changes': [
        {'job': 'writer', 'slot': 'first', 'bench_evidence': evidence}]}))
    (directory / 'latest.json').write_text(json.dumps({'proposal': str(proposal_path)}))
    lines = cost_report.compute_needs_you_lines(tmp_path)
    if defect == 'none':
        assert any('-ApproveEffort' in line for line in lines)
        assert any('model list is waiting for your OK' in line for line in lines)
        assert not any('stale or legacy' in line for line in lines)
    else:
        assert not any('-ApproveEffort' in line for line in lines)
        assert any('writer effort proposal has stale or legacy' in line for line in lines)
        assert any('model-list proposal includes stale or legacy' in line for line in lines)


@pytest.mark.parametrize('config', [
    ['invalid'], 'invalid', {'judges': ['claude-fable-5-1', 'gpt-6-astra']},
    {'judges': {'claude': ['claude-fable-5-1'], 'codex': 'gpt-6-astra'}},
    {'judges': {'claude': 'claude-fable-5-1', 'codex': 'gpt-6-astra', 'note': 'x'}},
    {'judges': {'claude': 'claude-fable-5-1', 'codex': 'gpt-6-astra'}, 'judge_effort': ['high']},
])
def test_weekly_malformed_judge_config_skips_disagreements(tmp_path: Path, config: object) -> None:
    import review
    digest = review.bank_hash(cost_report.REPO_ROOT / 'scripts/model-router/bench/tasks')
    (tmp_path / 'bench').mkdir()
    (tmp_path / 'bench/judge-config.json').write_text(json.dumps(config), encoding='utf-8')
    row = dict(source='bench', disagreement=True, task_bank_sha256=digest,
               judge_models=['claude-fable-5-1', 'gpt-6-astra'], judge_effort='high')
    (tmp_path / 'outcomes.jsonl').write_text(json.dumps(row) + '\n', encoding='utf-8')
    lines = cost_report.compute_needs_you_lines(tmp_path)
    assert any('golden review' in line for line in lines)
    assert not any('judge disagreements' in line for line in lines)
    assert json.loads((tmp_path / 'bench/judge-config.json').read_text(encoding='utf-8')) == config
