from __future__ import annotations

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import subprocess
import time
import os

import pytest

BENCH = Path(__file__).resolve().parents[1] / 'bench'
sys.path.insert(0, str(BENCH))
import bench_engine as engine
from codex_appserver import usage


@pytest.fixture(autouse=True)
def synthetic_native_auth(tmp_path, monkeypatch):
    source = tmp_path / 'native-auth-source'
    source.mkdir()
    (source / 'auth.json').write_text('{}', encoding='utf-8')
    monkeypatch.setenv('CODEX_HOME', str(source))


@pytest.mark.parametrize('newline', ['\n', '\r\n'])
def test_fenced_trailing_prose_line_endings(newline):
    assert engine.answer_body(newline.join(['```json', '{"value":42}', '```', 'Done.'])) == '{"value":42}'


@pytest.mark.parametrize('answer', ['````md\n```py\nx\n```\n````',
    '```py\n```json\nx\n```\n```', '```\nx\n```\n```'])
def test_ambiguous_nested_fences(answer):
    with pytest.raises(ValueError, match='Ambiguous'):
        engine.answer_body(answer)


def test_rubric_preserves_embedded_quote_and_whole_fence():
    prose = 'Our results improved.\n\n```text\nA quoted observation.\n```\n\nRisks remain.'
    assert engine.answer_body(prose, structured=False) == prose
    assert engine.answer_body('```text\nThe complete letter.\n```', structured=False) == 'The complete letter.'
    for kept in ('```text\nA\n```\nmid\n```text\nB\n```', '````md\nThe letter.\n````'):
        assert engine.answer_body(kept, structured=False) == kept


def test_native_config_does_not_relabel_unrelated_errors(tmp_path):
    import codex_appserver as transport
    with pytest.raises(FileNotFoundError):
        with transport.native_config_home(tmp_path):
            raise FileNotFoundError('synthetic missing binary')
    assert not list(tmp_path.glob('router-bench-native-home-*'))


def test_rubric_full_prose_reaches_judge(tmp_path):
    answer = 'Full opening.\n```text\nQuoted evidence.\n```\nFull closing.'
    seen = []
    def dispatch(request):
        if request['purpose'] == 'answer':
            return {'status': 'ok', 'answer': answer}
        seen.append(request['prompt'])
        return writer_judges(request)
    result = run(tmp_path, job='writer', effort='medium', dispatch=dispatch)
    assert seen and all(answer in prompt for prompt in seen)
    assert all(Path(row['answer_path']).read_text() == answer for row in result['outcomes'])


def test_native_config_reference_cleanup(tmp_path, monkeypatch):
    import codex_appserver as transport
    source = Path(os.environ['CODEX_HOME']) / 'auth.json'
    before = source.read_bytes()
    for key in ('OPENAI_API_KEY', 'CODEX_ACCESS_TOKEN', 'CODEX_CONFIG', 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_AUTH_TOKEN'):
        monkeypatch.setenv(key, 'HOSTILE_SENTINEL')
    home = None
    with pytest.raises(RuntimeError, match='synthetic interruption'):
        with transport.native_config_home(tmp_path) as env:
            home = Path(env['CODEX_HOME'])
            assert home != source.parent and not (home / 'config.toml').exists()
            assert (home / 'auth.json').is_symlink() and os.path.samefile(home / 'auth.json', source)
            assert all(key not in env for key in ('OPENAI_API_KEY', 'CODEX_ACCESS_TOKEN', 'CODEX_CONFIG', 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_AUTH_TOKEN'))
            raise RuntimeError('synthetic interruption')
    assert home is not None and not home.exists() and source.read_bytes() == before


def test_native_config_no_copy_fallback(tmp_path, monkeypatch):
    import codex_appserver as transport
    source = Path(os.environ['CODEX_HOME']) / 'auth.json'
    before = source.read_bytes()
    def unavailable(*args, **kwargs):
        raise OSError('synthetic unsupported symlink')
    monkeypatch.setattr(Path, 'symlink_to', unavailable)
    with pytest.raises(transport.BoundaryError, match='native auth reference unavailable'):
        with transport.native_config_home(tmp_path):
            pytest.fail('must not fallback to copied credentials')
    assert source.read_bytes() == before and not list(tmp_path.glob('router-bench-native-home-*'))


def test_native_dirty_config_rejected(tmp_path):
    import codex_appserver as transport
    with pytest.raises(transport.BoundaryError, match='nonempty native config layer'):
        transport.run([sys.executable, str(Path(__file__).with_name('fake-appserver.py')), 'dirty-layer'],
                      {'model':'gpt-6.1-sol','effort':'high','prompt':'Synthetic fixture\nexact bytes'}, tmp_path, 5000)
    assert not list(tmp_path.glob('router-bench-native-home-*'))


@pytest.mark.parametrize('identity', [None, {'comparison_valid':False}])
def test_failed_unknown_identity_usage_unpriced(identity):
    call = dict(vendor='codex', model='gpt-6.1-sol', quota={}, status='unknown',
                resolved_model=None, identity=identity, usage={'input':100,'output':10})
    prices = {'models': {'gpt-6.1-sol': {'prices_usd_per_mtok': {'input':1,'output':1}}}}
    result = engine.summarize_calls([call], prices)['codex']
    assert result['tokens'] == {'input':100,'output':10}
    assert result['unpriced_calls'] == 1 and result['priced_subtotal_usd'] == 0


@pytest.mark.parametrize('message', ['TIMEOUT', 'timed out', 'transport failed', 'transport failure'])
def test_timeout_classification(message):
    import codex_appserver as transport
    assert transport.failure_category(message) == 'transport'


# Captured TokenUsageBreakdown schema: only cacheWriteInputTokens is optional,
# with integer default 0. No generated schema file is needed by these tests.
_CODEX_USAGE = {'inputTokens': 100, 'cachedInputTokens': 40,
                'outputTokens': 8, 'reasoningOutputTokens': 2, 'totalTokens': 108}
_CODEX_DEFAULT = {'input': 60, 'cached_input': 40, 'cache_write': 0, 'output': 8}
_CODEX_USAGE_CASES = [
    pytest.param(dict(_CODEX_USAGE), _CODEX_DEFAULT, id='omitted-default'),
    pytest.param(dict(_CODEX_USAGE, cacheWriteInputTokens=0), _CODEX_DEFAULT, id='explicit-zero'),
    pytest.param(dict(_CODEX_USAGE, cacheWriteInputTokens=5),
                 {'input': 55, 'cached_input': 40, 'cache_write': 5, 'output': 8}, id='positive-write'),
]
_CODEX_USAGE_CASES += [
    pytest.param({k: v for k, v in _CODEX_USAGE.items() if k != missing}, None, id='missing-' + missing)
    for missing in _CODEX_USAGE
]
_CODEX_USAGE_CASES += [
    pytest.param(dict(_CODEX_USAGE, cacheWriteInputTokens=value), None, id='invalid-write-' + label)
    for label, value in [('null', None), ('true', True), ('false', False),
                         ('nan', float('nan')), ('inf', float('inf')), ('negative-inf', float('-inf')),
                         ('negative', -1), ('string', '0'), ('list', []), ('object', {}), ('float', 0.0)]
]
_CODEX_USAGE_CASES += [
    pytest.param(dict(_CODEX_USAGE, **patch), None, id='identity-' + label)
    for label, patch in [('partition-omitted', {'cachedInputTokens': 101}),
                         ('partition-write', {'cacheWriteInputTokens': 61}),
                         ('reasoning-omitted', {'reasoningOutputTokens': 9}),
                         ('reasoning-write', {'reasoningOutputTokens': 9, 'cacheWriteInputTokens': 5}),
                         ('total-omitted', {'totalTokens': 109}),
                         ('total-write', {'totalTokens': 109, 'cacheWriteInputTokens': 5})]
]
_CODEX_USAGE_CASES += [
    pytest.param(value, None, id='malformed-' + label)
    for label, value in [('null', None), ('list', []), ('string', 'bad'), ('bool', True), ('empty', {})]
]


@pytest.mark.parametrize('last,expected', _CODEX_USAGE_CASES)
def test_codex_usage_optional_cache_write(last: object, expected: dict[str, int] | None) -> None:
    before = deepcopy(last)
    actual = usage(last)
    assert actual == expected
    assert last == before
    if actual is not None:
        assert isinstance(last, dict)
        assert type(actual['cache_write']) is int
        assert actual['input'] + actual['cached_input'] + actual['cache_write'] == last['inputTokens']
        assert last['totalTokens'] == last['inputTokens'] + actual['output']
        assert last['reasoningOutputTokens'] <= actual['output']


def test_partial_nonfinite_usage_and_rates() -> None:
    calls = [{'vendor': 'claude', 'model': 'model', 'quota': {}, 'usage': u}
             for u in ({'input': 1}, {'input': float('nan'), 'output': 1},
                       {'input': 1, 'output': float('inf')}, {'input': True, 'output': 1})]
    result = engine.summarize_calls(calls, {})['claude']
    assert result['unmeasured_calls'] == 4 and result['measured_calls'] == 0
    calls[0]['usage'] = {'input': 10, 'output': 2}
    result = engine.summarize_calls(calls[:1], {'models': {'model': {'prices_usd_per_mtok': {'input': float('nan'), 'output': 1}}}})['claude']
    assert result['unpriced_calls'] == 1 and result['priced_subtotal_usd'] == 0


def test_dated_price_tie_report(tmp_path: Path) -> None:
    prices = {'models': {m: {'prices_usd_per_mtok': {'input': p, 'output': p}}
                         for m, p in [('candidate', 1), ('incumbent', 5)]}}
    result = run(tmp_path, candidate='candidate-20261002', incumbent='incumbent-20261002', prices=prices)
    assert result['tied'] and result['better'] is None
    assert 'price_recommendation' not in result
    assert 'Verdict: tied' in Path(result['report_paths']['markdown']).read_text()


def test_candidate_missing_module_is_failure() -> None:
    task = BENCH / 'tasks/complex-coding-ledger'
    result = engine.grade_answer(task, 'import candidate_package_that_does_not_exist\n')
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'


def test_ui_candidate_and_repo_missing_modules(tmp_path: Path) -> None:
    actual = engine.grade_answer(BENCH / 'tasks/ui-frontend-card', "import missing from 'candidate_missing_package'; export default () => <div/>;")
    assert actual['status'] == 'fail'
    harness = tmp_path / 'harness'
    harness.mkdir()
    (harness / 'render.cjs').write_text("console.error(\"Cannot find module 'jsdom'\\nRequire stack:\\n\"+__filename);process.exit(1)")
    (tmp_path / 'grader.py').write_text("import subprocess\nfrom pathlib import Path\np=subprocess.run(['node',str(Path(__file__).parent/'harness/render.cjs')],capture_output=True)\nraise SystemExit(p.returncode)\n")
    missing = engine.grade_answer(tmp_path, 'evidence')
    assert missing['status'] == 'unknown' and missing['failure_category'] == 'environment'


def test_repo_dependency_preflight_is_environment(tmp_path: Path) -> None:
    # Shadow only the child's package lookup, leaving the installed environment intact.
    (tmp_path / 'grader.py').write_text("raise AssertionError('grader must not run')\n")
    (tmp_path / 'task.json').write_text('{"grader":"pytest"}')
    wrapper = tmp_path / 'probe.py'
    wrapper.write_text('import importlib.util,runpy,sys\nimportlib.util.find_spec=lambda name: None\nsys.argv='+repr([str(BENCH / 'grader-runner.py'), str(tmp_path), str(tmp_path / 'answer')])+ '\nrunpy.run_path(sys.argv[0],run_name="__main__")\n')
    result = subprocess.run([sys.executable, str(wrapper)], capture_output=True, text=True, timeout=10)
    row = json.loads(result.stdout)
    assert row['status'] == 'unknown' and 'Missing repo harness dependency: pytest' in row['detail']


@pytest.mark.parametrize('task', ['mechanical-extract-table', 'mechanical-rename-sweep',
                                  'math-return-series', 'code-review-planted',
                                  'routine-coding-endpoint', 'complex-coding-ledger'])
def test_real_graders(task: str) -> None:
    directory = BENCH / 'tasks' / task
    assert engine.grade_answer(directory, (directory / 'known-good.txt').read_text(encoding='utf-8'))['status'] == 'pass'
    assert engine.grade_answer(directory, (directory / 'known-bad.txt').read_text(encoding='utf-8'))['status'] == 'fail'


def test_outer_boundary(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'CLAUDE_CONFIG_DIR'):
        monkeypatch.setenv(key, 'secret')
    (tmp_path / 'grader.py').write_text(
        "import os,socket,sys\n"
        "assert not any(k in os.environ for k in ['OPENAI_API_KEY','ANTHROPIC_API_KEY','CLAUDE_CONFIG_DIR'])\n"
        "assert os.getcwd()!=str(__import__('pathlib').Path(__file__).parent)\n"
        "try: socket.create_connection(('127.0.0.1',9))\n"
        "except RuntimeError: pass\n"
        "else: raise AssertionError('network allowed')\nprint('PASS')\n", encoding='utf-8')
    assert engine.grade_answer(tmp_path, 'evidence')['status'] == 'pass'
    (tmp_path / 'grader.py').write_text("import time\ntime.sleep(5)\n", encoding='utf-8')
    assert engine.grade_answer(tmp_path, 'evidence', timeout=.1)['status'] == 'unknown'
    (tmp_path / 'grader.py').write_text("raise RuntimeError('crash')\n", encoding='utf-8')
    assert engine.grade_answer(tmp_path, 'evidence')['status'] == 'unknown'


def run(tmp_path: Path, **overrides: object) -> dict:
    config = json.loads((BENCH / 'bench-config.json').read_text())
    arguments = dict(job='fast', candidate='candidate', incumbent='incumbent', trigger='manual',
                     effort='low', state_dir=tmp_path, tasks=BENCH / 'tasks', config=config,
                     dispatch=lambda request: {'status': 'ok', 'answer': '{}'},
                     limits=lambda vendor: {'blocked': False}, envelope=lambda answer: answer,
                     outcome=lambda row: None, grade=lambda task, answer: {'status': 'pass'})
    arguments.update(overrides)
    return engine.run_bench(**arguments)


def prompt_rubric(request: dict) -> dict:
    # Each writer task has its own rubric; the judge prompt carries it on one line.
    return next(json.loads(line) for line in request['prompt'].splitlines() if line.startswith('{"threshold"'))


def test_reps_shadow_baseline(tmp_path: Path) -> None:
    result = run(tmp_path)
    assert result['raw_gate'] == 'pass' and result['gate'] == 'advisory' and result['shadow']
    assert result['candidate']['passed'] == 3
    assert len(result['outcomes']) == 18
    assert result['effort_down'] is None
    assert len(json.loads((tmp_path / 'bench/baseline.json').read_text())) == 2
    assert all(row['attempt'] == 1 and row['source'] == 'bench' for row in result['outcomes'])


def test_environment_retry_and_quota(tmp_path: Path) -> None:
    calls = []
    result = run(tmp_path, limits=lambda vendor: {'blocked': True},
                 dispatch=lambda request: calls.append(request))
    assert not calls and result['raw_gate'] == 'unknown' and result['gate'] == 'unknown'
    assert len(result['outcomes']) == 36
    assert not json.loads((tmp_path / 'bench/baseline.json').read_text())
    counts = {}
    def grade(task: Path, answer: str) -> dict:
        counts[task.name] = counts.get(task.name, 0) + 1
        return {'status': 'unknown' if counts[task.name] == 1 else 'pass'}
    result = run(tmp_path / 'retry', grade=grade)
    assert result['raw_gate'] == 'pass' and len(result['outcomes']) == 21


def test_identity_failure_earns_a_third_attempt(tmp_path: Path) -> None:
    # Two identity failures in a row (the CLI answering on another model) still get a third try;
    # any other unknown stops at two attempts, and a third identity failure stays unknown.
    seen: dict[tuple, int] = {}
    def dispatch(request: dict) -> dict:
        key = (request['model'], request['prompt'][:40])
        seen[key] = seen.get(key, 0) + 1
        if request['model'] == 'candidate':
            if seen[key] <= 2:
                return {'status': 'unknown', 'failure_category': 'identity', 'detail': 'Claude model changed during comparison.'}
            return {'status': 'ok', 'answer': '{}'}
        if request['model'] == 'incumbent':
            return {'status': 'unknown', 'failure_category': 'environment', 'detail': 'timeout'}
        return {'status': 'ok', 'answer': '{}'}
    result = run(tmp_path, dispatch=dispatch)
    candidate = [row for row in result['outcomes'] if row['side'] == 'candidate']
    incumbent = [row for row in result['outcomes'] if row['side'] == 'incumbent']
    assert max(row['attempt'] for row in candidate) == 3 and all(not row['unknown'] for row in candidate if row['attempt'] == 3)
    assert result['candidate']['unknown'] == 0
    assert max(row['attempt'] for row in incumbent) == 2 and all(row['unknown'] for row in incumbent)
    always = run(tmp_path / 'always', dispatch=lambda request: {'status': 'unknown', 'failure_category': 'identity', 'detail': 'changed'})
    assert max(row['attempt'] for row in always['outcomes']) == 3 and always['raw_gate'] == 'unknown'


def test_deterministic_failure_no_retry(tmp_path: Path) -> None:
    result = run(tmp_path, grade=lambda task, answer: {'status': 'fail'})
    assert len(result['outcomes']) == 18
    assert not any(row['unknown'] for row in result['outcomes'])


def test_rubric_self_weight_and_effort_up(tmp_path: Path) -> None:
    config = json.loads((BENCH / 'bench-config.json').read_text())
    def dispatch(request: dict) -> dict:
        if request['purpose'] == 'answer':
            return {'status': 'ok', 'answer': 'answer evidence'}
        value = 0 if request['model'] == config['judges']['claude'] else 1
        return {'status': 'ok', 'answer': json.dumps({'scores': {line['id']: value for line in prompt_rubric(request)['lines']}})}
    result = run(tmp_path, job='writer', effort='medium', candidate=config['judges']['claude'], dispatch=dispatch)
    first = result['outcomes'][0]
    assert first['judge_average'] == pytest.approx(2 / 3)
    assert first['disagreement'] and first['status'] == 'fail'
    assert result['effort_down'] is None and result['effort_up']['effort'] == 'high'
    assert len(result['outcomes']) == 27


def test_binary_scores_and_strip() -> None:
    rubric = {'lines': [{'id': 'one'}]}
    assert engine.answer_body('[12:23:34] ```json\n{}\n```') == '{}'
    for value in (True, .5, '1'):
        with pytest.raises(ValueError):
            engine.judge_score(rubric, json.dumps({'scores': {'one': value}}))
    with pytest.raises(ValueError):
        engine.judge_score(rubric, '{"scores":{}}')
    assert engine.compare({'unknown': 0, 'passed': 3}, {'unknown': 0, 'passed': 4, 'tasks': [None] * 4}) == 'pass'
    assert engine.compare({'unknown': 0, 'passed': 2}, {'unknown': 0, 'passed': 4, 'tasks': [None] * 4}) == 'fail'


def test_executable_python_boundary(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv('OPENAI_API_KEY', 'secret')
    task = BENCH / 'tasks/routine-coding-endpoint'
    good = (task / 'known-good.txt').read_text(encoding='utf-8')
    guard = ("import os,socket\nassert 'OPENAI_API_KEY' not in os.environ\n"
             "assert __import__('pathlib').Path.cwd().joinpath('input.json').exists()\n"
             "for operation in [lambda: socket.create_connection(('127.0.0.1',9)), "
             "lambda: socket.socket(socket.AF_INET,socket.SOCK_DGRAM).sendto(b'x',('127.0.0.1',9))]:\n"
             "    try: operation()\n"
             "    except RuntimeError: pass\n"
             "    else: raise AssertionError('network allowed')\n")
    assert engine.grade_answer(task, guard + good)['status'] == 'pass'


def test_real_ui_boundary(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv('ANTHROPIC_API_KEY', 'secret')
    task = BENCH / 'tasks/ui-frontend-card'
    good = (task / 'known-good.txt').read_text(encoding='utf-8')
    guard = ("if (process.env.ANTHROPIC_API_KEY) throw Error('credential exposed');\n"
             "try {fetch('http://127.0.0.1:9'); throw Error('network allowed');} "
             "catch(e) {if (!String(e).includes('network disabled')) throw e;}\n")
    assert engine.grade_answer(task, guard + good)['status'] == 'pass'
    assert engine.grade_answer(task, (task / 'known-bad.txt').read_text(encoding='utf-8'))['status'] == 'fail'


def test_approved_gate_baseline_and_bank_reset(tmp_path: Path) -> None:
    tasks = tmp_path / 'copied-bank'
    shutil.copytree(BENCH / 'tasks', tasks, ignore=shutil.ignore_patterns('node_modules', '__pycache__', '.pytest_cache'))
    state = tmp_path / 'state'
    review = engine.Review(tasks, state / 'bench')
    digest = engine.bank_hash(tasks)
    for task_id in review.ids:
        assert review.choose(task_id, 'approved', digest)
    first = run(state, tasks=tasks)
    assert first['gate'] == 'pass' and not first['shadow']
    failure = run(state, tasks=tasks, grade=lambda t, a: {'status': 'fail'})
    assert len(failure['baseline_drops']) == 2
    assert all(d['before'] == 3 and d['after'] == 0 for d in failure['baseline_drops'])
    (tasks / 'mechanical-extract-table/fixtures/extra.txt').write_text('Synthetic additional input')
    changed = run(state, tasks=tasks)
    assert changed['shadow'] and changed['task_bank_sha256'] != digest
    assert not changed['baseline_drops']
    assert len(json.loads((state / 'bench/baseline.json').read_text())) == 4


def test_timeout_descendants_and_nested_temp(tmp_path: Path) -> None:
    marker = tmp_path / 'child.json'
    child = "import pathlib,os,time,json; pathlib.Path(" + repr(str(marker)) + ").write_text(json.dumps([os.getpid(),os.getcwd()])); time.sleep(20)"
    (tmp_path / 'grader.py').write_text(
        "import subprocess,sys,tempfile,time\n"
        "with tempfile.TemporaryDirectory(prefix='nested-synthetic-') as d:\n"
        " subprocess.Popen([sys.executable,'-c'," + repr(child) + "],cwd=d)\n"
        " time.sleep(20)\n")
    start = time.monotonic()
    result = engine.grade_answer(tmp_path, 'synthetic', timeout=1)
    assert result['status'] == 'unknown' and time.monotonic() - start < 8
    pid, work = json.loads(marker.read_text())
    assert not Path(work).exists() and not Path(work).parent.exists()
    if os.name == 'nt':
        listing = subprocess.run(['tasklist', '/FI', f'PID eq {pid}', '/FO', 'CSV'], capture_output=True, text=True, timeout=5)
        assert f'"{pid}"' not in listing.stdout
    else:
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)


def test_quota_read_failure_is_unknown(tmp_path: Path) -> None:
    def unavailable(vendor: str) -> dict:
        raise OSError('synthetic quota read error')
    result = run(tmp_path, limits=unavailable, dispatch=lambda r: pytest.fail('blocked dispatch'))
    assert result['raw_gate'] == 'unknown'


def test_invalid_and_dated_usage() -> None:
    prices = {'models': {'claude-opus-5-5': {'prices_usd_per_mtok': {'input': 2, 'output': 4}}}}
    calls = [{'vendor': 'claude', 'model': 'claude-opus-5-5-20261001', 'quota': {}, 'usage': u}
             for u in ({'input': 10, 'output': 2}, {}, {'input': -1, 'output': 2}, {'input': 1})]
    totals = engine.summarize_calls(calls, prices)['claude']
    assert totals['measured_calls'] == 1 and totals['unmeasured_calls'] == 3
    assert totals['priced_subtotal_usd'] == pytest.approx(.000028)


def test_actual_approved_gate_deficit_fail_unknown(tmp_path: Path) -> None:
    tasks = tmp_path / 'bank'
    shutil.copytree(BENCH / 'tasks', tasks, ignore=shutil.ignore_patterns('node_modules', '__pycache__', '.pytest_cache'))
    state = tmp_path / 'state'
    review = engine.Review(tasks, state / 'bench')
    digest = engine.bank_hash(tasks)
    for task_id in review.ids:
        assert review.choose(task_id, 'approved', digest)
    def dispatch(r: dict) -> dict:
        return {'status': 'ok', 'answer': r['model']}
    deficit = run(state, tasks=tasks, dispatch=dispatch,
                  grade=lambda t, a: {'status': 'fail' if a == 'candidate' and t.name == 'mechanical-extract-table' else 'pass'})
    assert deficit['gate'] == 'fail' and deficit['shortfall_tasks'] == 1
    failed = run(state, tasks=tasks, dispatch=dispatch,
                 grade=lambda t, a: {'status': 'fail' if a == 'candidate' else 'pass'})
    assert failed['gate'] == 'fail' and failed['shortfall_tasks'] == 3
    unknown = run(state, tasks=tasks, dispatch=dispatch,
                  grade=lambda t, a: {'status': 'unknown' if a == 'candidate' else 'pass'})
    assert unknown['gate'] == 'unknown'
    before = (state / 'bench/baseline.json').read_bytes()
    run(state, tasks=tasks, dispatch=lambda r: {'status': 'unknown'})
    assert (state / 'bench/baseline.json').read_bytes() == before
    fixture = tasks / 'mechanical-extract-table/fixtures/input.json'
    fixture.rename(fixture.with_name('renamed.json'))
    renamed = run(state, tasks=tasks)
    assert renamed['shadow'] and renamed['task_bank_sha256'] != digest


def test_blocked_judge_and_successful_retry(tmp_path: Path) -> None:
    requests = []
    result = run(tmp_path, job='writer', effort='low',
                 limits=lambda v: {'blocked': v == 'claude'},
                 dispatch=lambda r: requests.append(r) or {'status': 'ok', 'answer': 'synthetic'})
    assert result['raw_gate'] == 'unknown'
    assert not any(r['vendor'] == 'claude' for r in requests)
    attempts = {}
    def grade(t: Path, a: str) -> dict:
        attempts[t.name] = attempts.get(t.name, 0) + 1
        return {'status': 'unknown' if attempts[t.name] % 2 else 'pass'}
    retried = run(tmp_path / 'retry', grade=grade)
    assert retried['raw_gate'] == 'pass' and len(retried['outcomes']) == 36


def test_old_outer_only_timeout_reproduces_orphan(tmp_path: Path) -> None:
    marker = tmp_path / 'orphan-marker.json'
    child_code = "import os,time,pathlib; pathlib.Path(" + repr(str(marker)) + ").write_text(str(os.getpid())); time.sleep(20)"
    parent_code = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c'," + repr(child_code) + "]); time.sleep(20)"
    with pytest.raises(subprocess.TimeoutExpired):
        subprocess.run([sys.executable, '-c', parent_code], timeout=1,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = int(marker.read_text())
    try:
        if os.name == 'nt':
            listing = subprocess.run(['tasklist', '/FI', f'PID eq {pid}', '/FO', 'CSV'], capture_output=True, text=True, timeout=5)
            assert f'"{pid}"' in listing.stdout
        else:
            os.kill(pid, 0)
    finally:
        if os.name == 'nt':
            subprocess.run(['taskkill', '/PID', str(pid), '/T', '/F'], capture_output=True, timeout=5, check=True)
        else:
            os.kill(pid, 9)


def test_real_outcome_lock_overlap(tmp_path: Path) -> None:
    common = BENCH.parent / 'router-common.ps1'
    script = tmp_path / 'append.ps1'
    script.write_text("param($StateRoot,$Common,$Lane)\n. $Common\n1..12 | ForEach-Object {Add-RouterOutcome -StateDir $StateRoot -Row @{source='bench'; lane=$Lane; rep=$_}}\n")
    processes = [subprocess.Popen(['pwsh', '-NoProfile', '-File', str(script), str(tmp_path), str(common), str(lane)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE) for lane in range(2)]
    try:
        for process in processes:
            stdout, stderr = process.communicate(timeout=15)
            assert process.returncode == 0, stderr
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
    rows = [json.loads(line) for line in (tmp_path / 'outcomes.jsonl').read_text().splitlines()]
    assert len(rows) == 24 and len({(r['lane'], r['rep']) for r in rows}) == 24


def test_judge_refresh_and_unavailable_up(tmp_path: Path) -> None:
    config = json.loads((BENCH / 'bench-config.json').read_text())
    def dispatch(request: dict) -> dict:
        if request['purpose'] == 'answer':
            return {'status': 'ok', 'answer': 'synthetic evidence'}
        return {'status': 'ok', 'answer': json.dumps({'scores': {line['id']: 1 for line in prompt_rubric(request)['lines']}})}
    result = run(tmp_path, job='writer', effort='medium', dispatch=dispatch)
    assert not result['effort_down_qualified'] and not result['effort_up_qualified']
    config['judges']['codex'] = 'gpt-6-astra-new'
    changed = run(tmp_path, job='writer', effort='medium', config=config, dispatch=dispatch)
    assert not changed['baseline_drops']
    assert len(json.loads((tmp_path / 'bench/baseline.json').read_text())) == 6
    def unknown_up(request: dict) -> dict:
        return {'status': 'unknown'} if request['purpose'] == 'answer' and request['effort'] == 'high' else dispatch(request)
    unknown = run(tmp_path / 'unknown', job='writer', effort='medium', dispatch=unknown_up)
    assert not unknown['effort_down_qualified'] and unknown['effort_up']['unknown'] == 3


def test_price_usage_and_malformed_dispatch(tmp_path: Path) -> None:
    prices = {'models': {m: {'prices_usd_per_mtok': {'input': n, 'cached_input': .1, 'output': n * 2}} for m, n in [('candidate', 1), ('incumbent', 2)]}}
    def dispatch(request: dict) -> dict:
        assert 'Synthetic fixture fixtures/input.json:' in request['prompt']
        assert 'golden/answer' not in request['prompt']
        return {'status': 'ok', 'answer': '{}', 'usage': {'input': 100, 'cached_input': 50, 'output': 10}}
    result = run(tmp_path, dispatch=dispatch, prices=prices)
    assert result['tied'] and result['better'] is None
    assert result['telemetry']['codex']['measured_calls'] == 18
    assert result['telemetry']['codex']['priced_subtotal_usd'] == pytest.approx(.00333)
    malformed = run(tmp_path / 'malformed', dispatch=lambda r: None)
    assert malformed['raw_gate'] == 'unknown'
    with pytest.raises(ValueError, match='two distinct'):
        run(tmp_path / 'config', config={'judges': {'codex': 'one'}})


def test_pelican_manual_only(tmp_path: Path) -> None:
    calls = []
    result = run(tmp_path, job='illustrator', effort=None, trigger='research',
                 dispatch=lambda r: calls.append(r))
    assert not calls and result['raw_gate'] == 'advisory'
    manual = run(tmp_path / 'manual', job='illustrator', effort=None,
                 dispatch=lambda r: {'status': 'ok', 'answer': '<svg></svg>'})
    assert len(manual['calls']) == 2
    assert all(Path(r['artifact_path']).exists() for r in manual['outcomes'])
    same = run(tmp_path / 'same', job='illustrator', effort=None, candidate='same', incumbent='same',
               dispatch=lambda r: {'status': 'ok', 'answer': '<svg></svg>'})
    assert len(same['calls']) == 1 and len(same['outcomes']) == 1
import codex_appserver as transport

@pytest.mark.parametrize('failure', ['timeout', 'oserror', 'nonzero'])
def test_appserver_cleanup_failure_is_closed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, failure: str) -> None:
    server = transport.Server([sys.executable, str(Path(__file__).with_name('fake-appserver.py')), 'ok'], transport.controls([]), tmp_path, time.monotonic()+4)
    server.initialize()
    real_run = transport.subprocess.run
    def broken(*args, **kwargs):
        if failure == 'timeout': raise subprocess.TimeoutExpired('taskkill', 3)
        if failure == 'oserror': raise OSError('SYNTHETIC_SECRET_SENTINEL')
        return subprocess.CompletedProcess(args[0], 1)
    if os.name != 'nt':
        server.close()
        pytest.skip('Windows tree cleanup path')
    monkeypatch.setattr(transport.subprocess, 'run', broken)
    with pytest.raises(transport.BoundaryError, match='^process cleanup failed$'):
        server.close()
    assert server.process.poll() is not None
    assert not server.reader.is_alive()
    assert server.process.stdin.closed and server.process.stdout.closed

# Independently enumerate the candidate-visible contract, including non-JSON inputs.
_VISIBLE = {
    'mechanical-extract-table': ('input.json', 'document.txt'),
    'mechanical-rename-sweep': ('input.json',),
    'routine-coding-endpoint': ('input.json', 'app.py'),
    'complex-coding-ledger': ('input.json',), 'ui-frontend-card': ('input.json',),
    'code-review-planted': (), 'math-return-series': ('input.json',),
    'analysis-ddq-gaps': ('input.json',), 'planning-migration': ('input.json',),
    'deep-research-vendor': ('input.json',), 'writing-letter-section': ('input.json',),
    'pelican': ('input.json',),
    'grounding-absent-answer': ('input.json',), 'grounding-false-premise': ('input.json',),
    'grounding-quote-check': ('input.json',), 'grounding-missing-field': ('input.json', 'document.txt'),
    'writing-status-update': ('input.json',), 'writing-explainer-paragraph': ('input.json',),
}

@pytest.mark.parametrize('task_id', _VISIBLE)
def test_candidate_input_boundary(task_id: str, tmp_path: Path) -> None:
    task = BENCH / 'tasks' / task_id
    copied = tmp_path / task_id
    shutil.copytree(task, copied, ignore=shutil.ignore_patterns('node_modules', '__pycache__'))
    # Extra grading text must not silently become a task input.
    (copied / 'fixtures/score-leak.txt').write_text('HARNESS_ONLY_SCORE_SENTINEL')
    prompt = engine.candidate_prompt(copied)
    expected = (task / 'prompt.md').read_text(encoding='utf-8')
    for name in _VISIBLE[task_id]:
        expected += '\n\nSynthetic fixture fixtures/' + name + ':\n' + (task / 'fixtures' / name).read_text(encoding='utf-8')
    assert prompt == expected
    assert all(text not in prompt for text in ('bug_line', 'judge-positive', 'judge-negative',
                                              'HARNESS_ONLY_SCORE_SENTINEL', 'golden/',
                                              'known-good.txt', 'known-bad.txt', 'hidden_tests.py'))

@pytest.mark.parametrize('job', ['deep-thinker', 'writer'])
def test_judges_receive_all_rubric_source_evidence(tmp_path: Path, job: str) -> None:
    rubric_tasks = [p.parent for p in (BENCH / 'tasks').glob('*/task.json')
                    if json.loads(p.read_text())['job'] == job
                    and json.loads(p.read_text())['grader'] == 'rubric']
    captured = []
    envelope = 'EXACT_CANONICAL_ENVELOPE_SENTINEL'
    def dispatch(request: dict) -> dict:
        if request['purpose'] == 'answer':
            return {'status': 'ok', 'answer': 'answer'}
        captured.append(request)
        task = next(t for t in rubric_tasks if (t / 'prompt.md').read_text() in request['prompt'])
        rubric = json.loads((task / 'golden/rubric.json').read_text())
        assert engine.candidate_prompt(task) in request['prompt']
        assert json.dumps(rubric) in request['prompt']
        assert request['prompt'].endswith(envelope)
        assert 'judge-positive' not in request['prompt'] and 'judge-negative' not in request['prompt']
        return {'status': 'ok', 'answer': json.dumps({'scores': {line['id']: 1 for line in rubric['lines']}})}
    run(tmp_path, job=job, effort='medium', dispatch=dispatch, envelope=lambda answer: envelope)
    for task in rubric_tasks:
        for vendor in ('claude', 'codex'):
            # Three reps each for candidate, incumbent and effort-up; the deep thinker also runs effort-down.
            assert sum(r['vendor'] == vendor and (task / 'prompt.md').read_text() in r['prompt'] for r in captured) == (12 if job == 'deep-thinker' else 9)

@pytest.mark.parametrize('write', [None, 0, 5])
def test_codex_cache_write_cost(write: int | None) -> None:
    raw = dict(_CODEX_USAGE)
    if write is not None:
        raw['cacheWriteInputTokens'] = write
    normalized = usage(raw)
    prices = json.loads((BENCH / '../../../references/model-router/api-prices.json').read_text())
    result = engine.summarize_calls([{'model': 'gpt-6.1-sol', 'vendor': 'codex',
                                    'quota': {}, 'usage': normalized}], prices)['codex']
    assert result['measured_calls'] == 1 and result['unpriced_calls'] == 0
    assert result['priced_subtotal_usd'] == pytest.approx(0.000204 + (write or 0) * 0.5 / 1_000_000)
    assert result['tokens']['cache_write'] == (write or 0)


# Permanent regressions for independent M02 accounting/refusal findings.
import codex_appserver as t
PEER = Path(__file__).with_name('fake-appserver-accounting.py')
@pytest.mark.parametrize('case,total', [('raw216',216),('stale216',216),('invalid108',108),('cleanup108',108),('cleanup-oserror108',108),('cumulative162',162),('duplicate',108),('quota-notification',108),('quota-turn',108)])
def test_retained_usage(tmp_path,monkeypatch,case,total):
    if case.startswith('cleanup'):
        original=t.Server
        class Cleanup(original):
            def close(self):
                super().close()
                if self.controls_verified:
                    if case=='cleanup-oserror108': raise OSError('SECRET_SENTINEL')
                    raise t.BoundaryError('process cleanup failed')
        monkeypatch.setattr(t,'Server',Cleanup)
    with pytest.raises(t.BoundaryError) as caught:
        t.run([sys.executable,str(PEER),case], {'model':'gpt-6.1-sol','effort':'high','prompt':'Synthetic fixture\nexact bytes'},tmp_path,5000)
    error=caught.value
    assert sum(error.usage.values())==total
    assert error.usage_partial
    if case.startswith('quota'):
        assert str(error)=='ERROR: Usage limit reached; resets at 2099-10-02T20:00:00+00:00'
    assert 'SECRET_SENTINEL' not in str(error)
def test_partial_summary():
    result=engine.summarize_calls([{'vendor':'codex','model':'gpt-6.1-sol','quota':{},'status':'unknown','usage_partial':True,'usage':{'input':55,'cached_input':40,'cache_write':5,'output':8}}], {'models':{'gpt-6.1-sol':{'prices_usd_per_mtok':{'input':1,'cached_input':1,'cache_write':1,'output':1}}}})['codex']
    assert result['measured_calls']==0 and result['partial_calls']==1
    assert result['priced_subtotal_usd']==pytest.approx(0.000108)

def test_missing_cache_write_price_is_unpriced():
    result = engine.summarize_calls([{'vendor':'codex','model':'synthetic','quota':{},
        'status':'ok','usage':{'input':55,'cached_input':40,'cache_write':5,'output':8}}],
        {'models':{'synthetic':{'prices_usd_per_mtok':{'input':1,'cached_input':1,'output':1}}}})['codex']
    assert result['unpriced_calls'] == 1 and result['priced_subtotal_usd'] == 0
    assert result['tokens']['cache_write'] == 5
@pytest.mark.parametrize('case', ['ok','usage-duplicate'])
def test_complete_accounting(tmp_path,case):
    result=t.run([sys.executable,str(BENCH.parent/'tests/fake-appserver.py'),case],{'model':'gpt-6.1-sol','effort':'high','prompt':'Synthetic fixture\nexact bytes'},tmp_path,5000)
    assert result['status']=='ok' and not result['usage_partial']
    assert sum(result['usage'].values())==108

@pytest.mark.parametrize('encrypted,expected', [('opaque ciphertext',True),(None,True),(123,False),({'type':'function_call'},False)])
def test_opaque_reasoning_schema(encrypted,expected):
    assert t.valid_raw_item({'id':'r','type':'reasoning','summary':[], 'encrypted_content':encrypted}) is expected


@pytest.mark.parametrize('variant', ['valid','api','missing','null','extra','plan'])
def test_account_update_authentication(variant, tmp_path):
    request = {'model':'gpt-6.1-sol','effort':'high','prompt':'Synthetic fixture\nexact bytes'}
    command = [sys.executable, str(PEER), 'account:' + variant]
    if variant == 'valid':
        assert t.run(command, request, tmp_path, 5000)['status'] == 'ok'
    else:
        with pytest.raises(t.BoundaryError, match='account authentication'):
            t.run(command, request, tmp_path, 5000)


def writer_judges(request: dict) -> dict:
    if request["purpose"] == "answer":
        return {"status": "ok", "answer": "synthetic evidence"}
    return {"status": "ok", "answer": json.dumps({"scores": {line["id"]: 1 for line in prompt_rubric(request)["lines"]}})}


def test_judge_effort_is_fixed_and_recorded(tmp_path: Path) -> None:
    requests = []
    def dispatch(request: dict) -> dict:
        requests.append(request)
        return writer_judges(request)
    result = run(tmp_path, job="writer", effort="medium", dispatch=dispatch)
    assert {r["effort"] for r in requests if r["purpose"] == "answer"} == {"medium", "high"}
    assert {r["effort"] for r in requests if r["purpose"] == "judge"} == {"high"}
    assert result["judge_effort"] == "high"
    assert all(c["effort"] == "high" for c in result["calls"] if c["purpose"] == "judge")
    assert all(row["judge_effort"] == "high" and
               all(score["effort"] == "high" for score in row["judge_scores"])
               for row in result["outcomes"])
    assert "effort: high" in Path(result["report_paths"]["markdown"]).read_text()
    changed_config = json.loads((BENCH / "bench-config.json").read_text())
    changed_config["judge_effort"] = "medium"
    changed = run(tmp_path, job="writer", effort="medium", dispatch=writer_judges, config=changed_config)
    assert not changed["baseline_drops"]
    assert len(json.loads((tmp_path / "bench/baseline.json").read_text())) == 6


@pytest.mark.parametrize("value", [None, "max", "", True, [], {}])
def test_invalid_judge_effort_is_rejected_before_dispatch(tmp_path: Path, value: object) -> None:
    config = json.loads((BENCH / "bench-config.json").read_text())
    if value is None:
        config.pop("judge_effort")
    else:
        config["judge_effort"] = value
    with pytest.raises(ValueError, match="judge_effort"):
        run(tmp_path, config=config, dispatch=lambda request: pytest.fail("invalid config dispatched"))
    assert not (tmp_path / "bench").exists()


@pytest.mark.parametrize("self_points,other_points,expected", [(2, 5, "pass"), (1, 5, "fail"), (3, 5, "pass")])
def test_exact_weighted_rubric_threshold(tmp_path: Path, self_points: int, other_points: int, expected: str) -> None:
    config = json.loads((BENCH / "bench-config.json").read_text())
    def dispatch(request: dict) -> dict:
        if request["purpose"] == "answer":
            return {"status": "ok", "answer": "synthetic evidence"}
        points = self_points if request["model"] == config["judges"]["claude"] else other_points
        return {"status": "ok", "answer": json.dumps({"scores": {
            line["id"]: int(i < points) for i, line in enumerate(prompt_rubric(request)["lines"])}})}
    result = run(tmp_path, job="writer", candidate=config["judges"]["claude"],
                 effort="medium", dispatch=dispatch)
    rows = [row for row in result["outcomes"] if row["side"] == "candidate"]
    assert all(row["status"] == expected for row in rows)
    assert all([score["weight"] for score in row["judge_scores"]] == [1, 2] for row in rows)
    if self_points == 2:
        assert all(row["judge_average"] == 0.8 for row in rows)


@pytest.mark.parametrize("newline", ["\n", "\r\n", "\r"])
def test_review_production_grade_preserves_line_endings(newline):
    answer = "LINE: 13" + newline + "FIX: user.is_active and not user.is_banned" + newline
    assert engine.grade_answer(BENCH / "tasks/code-review-planted", answer)["status"] == "pass"


@pytest.mark.parametrize("usage,expected", [
    (dict(input=2, output=4, cache_read=6, cache_write_5m=7, cache_write_1h=13), .000569),
    (dict(input=2, output=4, cache_read=6, cache_write=20), None),
    (dict(input=2, output=4, cache_read=6, cache_write=0), .0002215),
    (dict(input=2, output=4, cache_read=6, cache_write=20, cache_write_5m=7, cache_write_1h=13), None),
])
def test_bench_claude_duration_or_unknown_cost(usage, expected):
    prices = json.loads((BENCH / "../../../references/model-router/api-prices.json").read_text())
    totals = engine.summarize_calls([dict(vendor="claude", model="claude-fable-5-1", quota={}, usage=usage)], prices)["claude"]
    assert totals["measured_calls"] == 1
    assert sum(totals["tokens"].values()) == sum(usage.values())
    if expected is None:
        assert totals["unpriced_calls"] == 1 and totals["priced_subtotal_usd"] == 0
    else:
        assert totals["unpriced_calls"] == 0 and totals["priced_subtotal_usd"] == pytest.approx(expected)


def test_unknown_claude_duration_stays_unpriced_with_legacy_rate():
    prices = {"models": {"claude-test": {"prices_usd_per_mtok": {
        "input": 10, "output": 50, "cache_read": .25, "cache_write": 12.5}}}}
    result = engine.summarize_calls([dict(vendor="claude", model="claude-test", quota={},
        usage=dict(input=2, output=3, cache_read=4, cache_write=10))], prices)["claude"]
    assert result["unpriced_calls"] == 1 and result["priced_subtotal_usd"] == 0


@pytest.mark.parametrize('answer,expected', [
    ('Here is the answer:\n```json\n{"value": 1}\n```\nTrailing prose with `inline` ticks.', '{"value": 1}'),
    ('Prose containing ``` incidental backticks.', 'Prose containing ``` incidental backticks.'),
    ('```json\n{}\n```', '{}'),
])
def test_single_fenced_answer_with_prose(answer, expected):
    assert engine.answer_body(answer) == expected


def test_ambiguous_fenced_answers_rejected():
    text = '```json\n{}\n```\nthen\n```json\n[]\n```'
    with pytest.raises(ValueError, match='Ambiguous answer: multiple'):
        engine.answer_body(text)
    assert engine.grade_answer(BENCH / 'tasks/math-return-series', text)['status'] == 'fail'


def test_saved_correct_math_answers_replay():
    saved = json.loads(Path(__file__).with_name('fixtures').joinpath('bench-math-saved-answers.json').read_text(encoding='utf-8'))
    assert len(saved) == 2
    for record in saved:
        assert record['bank_sha256'] == '154bde92847354319143dcf5052029edd930dc3a3714e2bd7446a35c04330bd7'
        assert engine.grade_answer(BENCH / 'tasks/math-return-series', record['answer'])['status'] == 'pass'


@pytest.mark.parametrize('key', ['developer_instructions', 'instructions'])
@pytest.mark.parametrize('mode', ['missing', 'enabled', 'unsupported'])
def test_codex_hostile_instruction_controls(key, mode, tmp_path):
    with pytest.raises(t.BoundaryError, match='instruction controls'):
        t.run([sys.executable, str(BENCH.parent / 'tests/fake-appserver.py'), f'instruction:{key}:{mode}'],
              {'model':'gpt-6.1-sol', 'effort':'high', 'prompt':'Synthetic fixture\nexact bytes'}, tmp_path, 5000)


def test_first_attempt_failures_do_not_blame_answer_model_for_judge():
    rows = [dict(attempt=1, side='candidate', model='answer-model', status='unknown', response={'status':'ok'},
                 judge_scores=[dict(model='actual-judge', response={'status':'unknown', 'failure_category':'protocol'}, error='unavailable')]),
            dict(attempt=2, side='candidate', model='answer-model', status='pass', response={'status':'ok'}),
            dict(attempt=1, side='candidate', model='answer-model', status='fail', response={'status':'ok'}),
            dict(attempt=1, side='candidate', model='answer-model', status='unknown', response={'status':'unknown','failure_category':'transport'})]
    actual = engine.summarize_first_attempts(rows)
    assert actual['candidate']['answer_reps'] == 3
    assert (actual['candidate']['lane'], actual['candidate']['model']) == ('candidate', 'answer-model')
    assert actual['actual-judge']['lane'] == 'judge'
    assert actual['candidate']['answer_quality_failures'] == 1
    assert actual['candidate']['answer_dispatch_failures'] == 1
    assert actual['candidate']['judge_dispatch_failures'] == 0
    assert actual['actual-judge']['answer_reps'] == 0
    assert actual['actual-judge']['judge_calls'] == actual['actual-judge']['judge_dispatch_failures'] == 1
    assert actual['actual-judge']['failure_categories'] == {'protocol':1}
