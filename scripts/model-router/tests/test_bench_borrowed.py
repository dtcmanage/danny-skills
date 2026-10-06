from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import sys
import shutil
import types
from uuid import UUID
import pytest
BENCH = Path(__file__).resolve().parents[1] / 'bench'
sys.path.insert(0, str(BENCH))
import add_task
import bench_engine as engine
import import_aider
import import_hle
import review


def exercise(tmp_path: Path, language: str, *, broken: bool = False) -> Path:
    root = tmp_path / 'clone' / language / 'exercises/practice/synthetic-double'
    (root / '.docs').mkdir(parents=True, exist_ok=True)
    (root / '.meta').mkdir(exist_ok=True)
    (root / '.docs/instructions.md').write_text('Double a synthetic number.')
    (root / '.docs/instructions.append.md').write_text('Preserve zero.')
    python = language == 'python'
    stub = 'synthetic_double.py' if python else 'synthetic-double.js'
    test = 'synthetic_double_test.py' if python else 'synthetic-double.spec.js'
    reference = '.meta/example.py' if python else '.meta/proof.ci.js'
    bad = 'def double(x): return 0\n' if python else 'export const double = x => 0;'
    good = 'def double(x): return x * 2\n' if python else 'export const double = x => x * 2;'
    (root / stub).write_text(bad)
    (root / reference).write_text(bad if broken else good)
    tests = ('from __future__ import annotations\nimport unittest\nfrom synthetic_double import double\nclass DoubleTest(unittest.TestCase):\n'
             '    def test_double(self): self.assertEqual(double(3), 6)\n') if python else '''
import {double} from './synthetic-double';
describe('synthetic', () => {
 let value;
 beforeEach(() => { value = double(3); });
 test('basic', () => { expect(value).toBe(6); expect([value]).toEqual([6]);
   expect(value).not.toBe(0); expect(value).toBeCloseTo(6); expect(value).toBeGreaterThan(5);
   expect(value).toBeLessThan(7); expect([value]).toHaveLength(1); expect([value]).toContain(6);
   expect('six').toMatch(/ix/); expect({}).toBeInstanceOf(Object);
   expect(undefined).toBeUndefined(); expect(null).toBeNull(); expect(value).toBeDefined();
   expect(value).toBeTruthy(); expect(0).toBeFalsy();
   expect(() => {throw new TypeError('synthetic');}).toThrow(TypeError);
   expect(() => {throw new Error('synthetic');}).toThrowError('synthetic'); });
 xtest('enabled xtest', () => expect(double(2)).toBe(4));
 xit('enabled xit', () => expect(double(1)).toBe(2));
 it('ordinary it', () => expect(double(0)).toBe(0));
});
'''
    (root / test).write_text(tests)
    (root / '.meta/config.json').write_text(json.dumps({'files': {'solution': [stub], 'test': [test], 'example': [reference]}}))
    return root


def imported(tmp_path: Path, language: str, **kwargs) -> Path:
    exercise(tmp_path, language, **kwargs)
    state = tmp_path / 'state'; state.mkdir(exist_ok=True)
    ids = tmp_path / 'ids.txt'; ids.write_text(language + '/synthetic-double\n')
    reports = import_aider.import_tasks(tmp_path / 'clone', ids, state)
    assert 'imported' in reports[0], reports
    return review.private_bank_path(state) / ('aider-' + language + '-synthetic-double')


@pytest.mark.parametrize('language', ['python', 'javascript'])
def test_aider_import_load_grade_duplicate(tmp_path: Path, language: str):
    task = imported(tmp_path, language)
    metadata = json.loads((task / 'task.json').read_text())
    assert metadata['category'] == 'complex-coding' and metadata['difficulty'] == 'hard'
    assert metadata['job'] == 'coder' and metadata['grader'] == ('pytest' if language == 'python' else 'nodetest')
    assert review.task_folders(BENCH / 'tasks', task.parent)[task.name] == (task, True)
    prompt = engine.candidate_prompt(task, private=True)
    assert 'Preserve zero' in prompt and 'one fenced block' in prompt
    assert engine.grade_answer(task, (task / 'known-good.txt').read_text())['status'] == 'pass'
    assert engine.grade_answer(task, (task / 'known-bad.txt').read_text())['status'] == 'fail'
    reports = import_aider.import_tasks(tmp_path / 'clone', tmp_path / 'ids.txt', tmp_path / 'state')
    assert 'Duplicate task id' in reports[0]
    if language == 'javascript':
        verdict = engine.grade_answer(task, (task / 'known-good.txt').read_text())
        result = json.loads(verdict['grader_output'])
        assert result['passed'] == 4 and result['skipped'] == 0 and result['failures'] == []
        assert engine.grade_answer(task, 'throw new Error("bad candidate")')['status'] == 'fail'
        assert engine.grade_answer(task, 'export const double = x => {while(true){}};', timeout=2)['status'] == 'fail'
        assert engine.grade_answer(task, 'import net from "node:net"; net.connect(80,"example.invalid");')['status'] == 'fail'


@pytest.mark.parametrize('language', ['python', 'javascript'])
def test_aider_bad_reference_removed(tmp_path: Path, language: str):
    exercise(tmp_path, language, broken=True)
    state = tmp_path / 'state'; state.mkdir()
    ids = tmp_path / 'ids.txt'; ids.write_text(language + '/synthetic-double')
    reports = import_aider.import_tasks(tmp_path / 'clone', ids, state)
    assert 'task removed' in reports[0]
    assert not list(review.private_bank_path(state).glob('*/task.json'))


@pytest.mark.parametrize('module', [import_aider, import_hle])
def test_refuse_repo_state(module, tmp_path: Path):
    with pytest.raises(ValueError, match='outside the repo'):
        module.import_tasks(tmp_path / 'absent', tmp_path / 'absent', BENCH)
    with pytest.raises(ValueError, match='outside the repo'):
        module.import_tasks(tmp_path / 'absent', tmp_path / 'absent', add_task.main_checkout())


def test_hle_selection_grading_and_reports(tmp_path: Path):
    state = tmp_path / 'state'; state.mkdir()
    rows = [dict(id='synthetic-' + str(i), question='Synthetic question ' + str(i), answer=a,
                 answer_type=t, image=image, category='synthetic', raw_subject='synthetic')
            for i, (a,t,image) in enumerate([('7', 'exactMatch', ''), ('true', 'exactMatch', ''),
                ('A', 'multipleChoice', ''), ('7', 'exactMatch', 'image-data')])]
    source = tmp_path / 'source.jsonl'; source.write_text('\n'.join(json.dumps(r) for r in rows))
    ids = tmp_path / 'ids.txt'; ids.write_text('\n'.join(r['id'] for r in rows) + '\nmissing')
    reports = import_hle.import_tasks(source, ids, state)
    assert 'answer_type' in reports[2] and 'image' in reports[3] and 'not found' in reports[4]
    for i, grader in [(0,'numeric'), (1,'exact')]:
        task = review.private_bank_path(state) / ('hle-synthetic-' + str(i))
        metadata = json.loads((task / 'task.json').read_text())
        assert metadata['grader'] == grader and metadata['job'] == 'deep-thinker'
        assert metadata['category'] == 'math' and metadata['difficulty'] == 'hard'
        assert task.name in review.task_folders(BENCH / 'tasks', task.parent)
        assert engine.grade_answer(task, (task / 'known-good.txt').read_text())['status'] == 'pass'
        assert engine.grade_answer(task, '{"answer": 0}' if i == 0 else 'orange')['status'] == 'fail'
    assert 'Duplicate task id' in import_hle.import_tasks(source, ids, state)[0]


def table(*statuses: tuple[str, list[str]]) -> dict:
    tasks = [{'task_id': name, 'private': True, 'reps': reps, 'status': 'pass' if reps.count('pass') >= 2 else 'fail'} for name,reps in statuses]
    return {'tasks': tasks, 'passed': sum(t['status'] == 'pass' for t in tasks), 'unknown': 0}


def test_discrimination_history_per_task_job_tier_and_reps(tmp_path: Path):
    good = ('good', ['pass'] * 3); bad = ('bad', ['fail'] * 3)
    mixed = ('mixed', ['pass', 'fail', 'pass'])
    tables = [table(good, bad, mixed), table(good, bad, mixed), table(good, bad, mixed)]
    old = tmp_path / 'runs/old/report.json'; old.parent.mkdir(parents=True)
    old.write_text(json.dumps({'job': 'coder', 'tier': 'hard', 'candidate': tables[0], 'incumbent': tables[1], 'effort_down': tables[2]}))
    excluded, drops = engine.discrimination(tables, tmp_path, 'coder', 'hard', 'new')
    assert excluded == ['bad'] and drops == [{'task_id': 'good', 'run_ids': ['old','new']}]
    assert engine.discrimination(tables, tmp_path, 'writer', 'hard', 'new')[1] == []
    assert engine.discrimination(tables, tmp_path, 'coder', 'standard', 'new')[1] == []
    # An intervening run that included it and failed breaks the streak.
    newer = tmp_path / 'runs/newer/report.json'; newer.parent.mkdir()
    newer.write_text(json.dumps({'job':'coder', 'tier':'hard', 'candidate':table(('good',['fail']*3)), 'incumbent':tables[1]}))
    assert engine.discrimination(tables, tmp_path, 'coder', 'hard', 'new')[1] == []
    tables[2]['tasks'][1]['reps'][0] = 'unknown'
    assert engine.discrimination(tables, tmp_path, 'coder', 'hard', 'new')[0] == []
    assert not engine.has_informative_evidence([table(bad)], {'bad'})
    assert engine.has_informative_evidence([table(bad)], {'bad'},
        {'verdict':'no_difference', 'tasks':[{'candidate_wins':1, 'incumbent_wins':1}]})
    assert not engine.has_informative_evidence([table(bad)], {'bad'},
        {'verdict':'no_difference', 'tasks':[{'candidate_wins':0, 'incumbent_wins':0}]})


def run_engine(tmp_path: Path, grades: dict[str,str], *, effort: str = 'medium') -> dict:
    state = tmp_path / 'state'; state.mkdir(exist_ok=True)
    for name in grades:
        problem = tmp_path / (name + '.md'); problem.write_text('Synthetic task')
        answer = tmp_path / (name + '.txt'); answer.write_text('synthetic')
        if not (review.private_bank_path(state) / name).exists():
            add_task.add_task(state=state, problem=problem, answer=answer, job='coder', grader='exact', difficulty='hard', task_id=name)
    tasks = tmp_path / 'empty-tasks'; tasks.mkdir(exist_ok=True)
    return engine.run_bench(job='coder', candidate='gpt-test', incumbent='claude-test', trigger='manual', effort=effort,
        state_dir=state, tasks=tasks, config={'judges':{'claude':'claude-judge','codex':'gpt-judge'},'judge_effort':'high'},
        dispatch=lambda r: {'status':'ok','answer':'synthetic'}, limits=lambda v: {'blocked':False},
        envelope=lambda t:t, outcome=lambda r:None, grade=lambda t,a: {'status':grades[t.name]}, _tier='hard')


def test_all_fail_insufficient_no_effort_no_tie(tmp_path: Path):
    result = run_engine(tmp_path, {'synthetic-fail':'fail'})
    assert result['uninformative_tasks'] == ['synthetic-fail'] and result['insufficient_evidence']
    assert result['raw_gate'] == 'unknown' and not result['tied'] and result['better'] is None
    assert not result['effort_down_qualified'] and not result['effort_up_qualified']
    assert not list((tmp_path / 'state/tie-proposals').glob('*.json'))
    assert 'insufficient evidence' in Path(result['report_paths']['markdown']).read_text()


def test_informative_and_drop_reports(tmp_path: Path):
    first = run_engine(tmp_path, {'synthetic-pass':'pass','synthetic-fail':'fail'})
    assert first['proposed_drops'] == [] and not first['insufficient_evidence']
    assert first['candidate']['passed'] == 1 and first['tied'] and first['effort_down_qualified']
    second = run_engine(tmp_path, {'synthetic-pass':'pass','synthetic-fail':'fail'})
    assert second['proposed_drops'] == [{'task_id':'synthetic-pass','run_ids':[
        Path(first['report_paths']['json']).parent.name, Path(second['report_paths']['json']).parent.name]}]
    assert 'Proposed drops' in Path(second['report_paths']['markdown']).read_text()
    assert (review.private_bank_path(tmp_path / 'state') / 'synthetic-pass').exists()


def test_gate_allowance_excludes_uninformative():
    incumbent = table(('one',['pass']*3), ('two',['pass']*3), ('three',['pass']*3), ('excluded',['fail']*3))
    candidate = table(('one',['pass']*3), ('two',['pass']*3), ('three',['fail']*3), ('excluded',['fail']*3))
    incumbent['tasks'][-1]['uninformative'] = True
    candidate['tasks'][-1]['uninformative'] = True
    assert engine.compare(candidate, incumbent) == 'fail'


def test_node_environment_problem(tmp_path: Path, monkeypatch):
    task = imported(tmp_path, 'javascript')
    monkeypatch.setenv('PATH', '')
    result = engine.grade_answer(task, (task / 'known-good.txt').read_text())
    assert result['status'] == 'unknown' and result['failure_category'] == 'environment'


@pytest.mark.parametrize('module,language', [('import_aider.py','python'), ('import_hle.py',None)])
def test_importer_cli(tmp_path: Path, module: str, language: str | None):
    state = tmp_path / 'state'; state.mkdir()
    ids = tmp_path / 'ids.txt'
    if language:
        exercise(tmp_path, language)
        source = tmp_path / 'clone'
        ids.write_text('python/synthetic-double')
    else:
        source = tmp_path / 'source.jsonl'
        source.write_text(json.dumps(dict(id='cli-synthetic', question='Synthetic question', answer='seven',
            answer_type='exactMatch', image='', category='synthetic', raw_subject='synthetic')))
        ids.write_text('cli-synthetic')
    args = [sys.executable, str(BENCH / module), '--source', str(source), '--ids', str(ids), '--state', str(state)]
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0 and 'imported' in result.stdout
    refused = subprocess.run(args[:-1] + [str(BENCH)], capture_output=True, text=True, timeout=30)
    assert refused.returncode != 0 and 'outside the repo' in refused.stderr


def test_no_private_bank_preserves_counts_and_report(tmp_path: Path, monkeypatch):
    task = tmp_path / 'tasks/synthetic-public'; task.mkdir(parents=True)
    (task / 'task.json').write_text(json.dumps(dict(job='fast', grader='exact', category='mechanical')))
    (task / 'prompt.md').write_text('Synthetic public task')
    monkeypatch.setitem(engine.CANDIDATE_INPUTS, task.name, ())
    state = tmp_path / 'state'; state.mkdir()
    result = engine.run_bench(job='fast', candidate='gpt-test', incumbent='claude-test', trigger='manual', effort='low',
        state_dir=state, tasks=task.parent, config={'judges':{'claude':'claude-judge','codex':'gpt-judge'},'judge_effort':'high'},
        dispatch=lambda r: {'status':'ok','answer':'seven'}, limits=lambda v: {'blocked':False},
        envelope=lambda t:t, outcome=lambda r:None, grade=lambda t,a: {'status':'pass'})
    assert result['uninformative_tasks'] == result['proposed_drops'] == []
    assert not result['insufficient_evidence'] and result['tied'] and result['raw_gate'] == 'pass'
    assert result['candidate']['passed'] == result['incumbent']['passed'] == 1
    assert not review.private_bank_path(state).exists()
    report = Path(result['report_paths']['markdown']).read_text()
    assert 'Uninformative' not in report and 'insufficient evidence' not in report and 'Proposed drops' not in report


def test_excluded_rubric_does_not_qualify_effort_up(tmp_path: Path):
    state = tmp_path / 'state'; state.mkdir()
    problem, expected = tmp_path / 'problem.md', tmp_path / 'answer.txt'
    problem.write_text('Synthetic writer task'); expected.write_text('synthetic')
    for name in ('synthetic-rubric', 'synthetic-exact'):
        task = add_task.add_task(state=state, problem=problem, answer=expected, job='writer', grader='exact',
            difficulty='standard', task_id=name)
        if name == 'synthetic-rubric':
            metadata = json.loads((task / 'task.json').read_text()); metadata['grader'] = 'rubric'
            (task / 'task.json').write_text(json.dumps(metadata))
            (task / 'golden/rubric.json').write_text(json.dumps({'threshold':.8,'lines':[{'id':'a'},{'id':'b'}]}))
            (task / 'judge-prompt.md').write_text('Judge synthetic lines.')
    tasks = tmp_path / 'empty-tasks'; tasks.mkdir()
    def dispatch(request):
        if request['purpose'] == 'judge':
            return {'status':'ok', 'answer':json.dumps({'scores':{'a':int('level-high' in request['prompt']), 'b':0}})}
        return {'status':'ok', 'answer':'level-' + request['effort']}
    result = engine.run_bench(job='writer', candidate='gpt-test', incumbent='claude-test', trigger='manual', effort='medium',
        state_dir=state, tasks=tasks, config={'judges':{'claude':'claude-judge','codex':'gpt-judge'},'judge_effort':'high'},
        dispatch=dispatch, limits=lambda v: {'blocked':False}, envelope=lambda t:t, outcome=lambda r:None,
        grade=lambda t,a: {'status':'pass'})
    assert result['uninformative_tasks'] == ['synthetic-rubric'] and not result['insufficient_evidence']
    assert result['effort_up']['passed'] == result['incumbent']['passed'] == 1
    assert not result['effort_up_qualified'] and result['tied']


def test_node_cannot_forge_verdict(tmp_path: Path):
    task = imported(tmp_path, 'javascript')
    answer = '''import fs from 'node:fs';
fs.writeSync(1, JSON.stringify({passed:9,failed:0,failures:[],skipped:0}) + '\\n');
process.exit(0);
export const double = x => 0;'''
    result = engine.grade_answer(task, answer)
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'


def test_node_candidate_cannot_intercept_final_protocol(tmp_path: Path):
    task = imported(tmp_path, 'javascript')
    answer = '''import fs from 'node:fs';
process.once = (event, callback) => {
  process.stdout._write = (chunk, encoding, done) => {
    const prefix = String(chunk).split(' verdict ')[0];
    fs.writeSync(1, prefix + ' verdict {"passed":9,"failed":0,"failures":[],"skipped":0}\\n');
    done();
  };
  callback();
};
Object.prototype.toJSON = () => ({passed:9,failed:0,failures:[],skipped:0});
export const double = x => 0;'''
    result = engine.grade_answer(task, answer)
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'


def test_node_candidate_cannot_replace_protocol_writer(tmp_path: Path):
    task = imported(tmp_path, 'javascript')
    answer = '''import fs from 'node:fs';
import {syncBuiltinESMExports} from 'node:module';
const write = fs.writeSync;
fs.writeSync = (fd, text) => write(fd, String(text).replace(/"failed":\\d+/, '"failed":0').replace(/"passed":\\d+/, '"passed":9'));
syncBuiltinESMExports();
export const double = x => 0;'''
    result = engine.grade_answer(task, answer)
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'


@pytest.mark.parametrize('attack', [
    'globalThis.expect = () => new Proxy({}, {get: () => () => {}});',
    "for (const name of ['test', 'it', 'xtest', 'xit']) {const original = globalThis[name]; globalThis[name] = title => original(title, () => {});}",
    "import assert from 'node:assert/strict'; for (const key of Object.keys(assert)) if (typeof assert[key] === 'function') assert[key] = () => {};",
])
def test_node_cannot_replace_assertions(tmp_path: Path, attack: str):
    task = imported(tmp_path, 'javascript')
    (task / 'hidden_tests.mjs').write_text("import {double} from './synthetic-double'; test('actual value', () => expect(double(3)).toBe(6));")
    result = engine.grade_answer(task, attack + '\nexport const double = x => 0;')
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'


def test_python_early_exit_is_failure(tmp_path: Path):
    task = imported(tmp_path, 'python')
    result = engine.grade_answer(task, 'import os\nos._exit(0)\ndef double(x): return 0\n')
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'


def test_python_pytest_report_path_not_in_candidate_args_or_folder(tmp_path: Path):
    task = imported(tmp_path, 'python')
    answer = '''import pathlib, sys
assert not any('junitxml' in value for value in sys.argv)
assert not list(pathlib.Path.cwd().glob('*.xml'))
def double(x): return x * 2
'''
    assert engine.grade_answer(task, answer)['status'] == 'pass'


@pytest.mark.parametrize('answer', [
    'process.exit(1); export const double = x => 0;',
    'await new Promise(() => {}); export const double = x => 0;',
    'setTimeout(() => {throw new Error("late failure");}, 10); export const double = x => x * 2;',
    'export const double = async x => new Promise(() => {});',
])
def test_node_abnormal_exit_is_implementation_failure(tmp_path: Path, answer: str):
    task = imported(tmp_path, 'javascript')
    if 'async x' in answer:
        (task / 'hidden_tests.mjs').write_text("import {double} from './synthetic-double'; test('pending', async () => expect(await double(3)).toBe(6));")
    result = engine.grade_answer(task, answer, timeout=2)
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'


def test_python_hang_is_implementation_failure(tmp_path: Path):
    task = imported(tmp_path, 'python')
    result = engine.grade_answer(task, 'while True: pass\ndef double(x): return 0\n', timeout=2)
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'


def test_node_child_process_is_refused(tmp_path: Path):
    task = imported(tmp_path, 'javascript')
    answer = '''import {spawnSync} from 'node:child_process';
const child = spawnSync(process.execPath, ['-e', 'process.exit(0)']);
if (child.status === 0) throw new Error('child succeeded');
export const double = x => x * 2;'''
    # Catch the refusal so a pass proves the child could not run.
    answer = answer.replace('const child = spawnSync', 'let child; try { child = spawnSync').replace("if (child.status", "} catch (error) { if (error.code !== 'ERR_ACCESS_DENIED') throw error; }\nif (child?.status")
    assert engine.grade_answer(task, answer)['status'] == 'pass'


def test_node_nonce_hidden_and_all_test_globals_locked(tmp_path: Path):
    task = imported(tmp_path, 'javascript')
    answer = '''if (process.env.BENCH_NODE_NONCE !== undefined) throw new Error('nonce exposed');
for (const name of ['describe', 'test', 'it', 'xtest', 'xit', 'beforeEach', 'expect']) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
  if (descriptor.writable || descriptor.configurable) throw new Error('global can be replaced: ' + name);
}
export const double = x => x * 2;'''
    assert engine.grade_answer(task, answer)['status'] == 'pass'


def test_node_counts_registered_bodies_not_run_after_hook_failure(tmp_path: Path):
    task = imported(tmp_path, 'javascript')
    (task / 'hidden_tests.mjs').write_text("beforeEach(() => {throw new Error('hook');}); test('unrun one', () => {}); xit('unrun two', () => {});")
    result = engine.grade_answer(task, (task / 'known-good.txt').read_text())
    verdict = json.loads(result['grader_output'])
    assert result['status'] == 'fail' and verdict['skipped'] == 2
    assert verdict['passed'] == 0 and verdict['failed'] == 2


@pytest.mark.parametrize('language', ['python', 'javascript'])
def test_aider_rejects_stub_that_passes(tmp_path: Path, language: str):
    root = exercise(tmp_path, language)
    name = 'synthetic_double.py' if language == 'python' else 'synthetic-double.js'
    (root / name).write_text('def double(x): return x * 2\n' if language == 'python' else 'export const double = x => x * 2;')
    state = tmp_path / 'state'; state.mkdir()
    ids = tmp_path / 'ids.txt'; ids.write_text(language + '/synthetic-double')
    reports = import_aider.import_tasks(tmp_path / 'clone', ids, state)
    assert 'Known-bad' in reports[0] and 'task removed' in reports[0]
    assert not list(review.private_bank_path(state).glob('*/task.json'))


@pytest.mark.parametrize('module', [import_aider, import_hle])
def test_relative_and_junction_repo_state_refused(tmp_path: Path, monkeypatch, module):
    monkeypatch.chdir(add_task.REPO)
    with pytest.raises(ValueError, match='outside the repo'):
        module.import_tasks(tmp_path / 'absent', tmp_path / 'absent', Path('scripts/model-router'))
    link = tmp_path / 'repo-junction'
    if os.name == 'nt':
        command = "New-Item -ItemType Junction -Path '" + str(link).replace("'", "''") + "' -Target '" + str(BENCH.parent).replace("'", "''") + "' | Out-Null"
        result = subprocess.run(['powershell', '-NoProfile', '-Command', command],
                                capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stderr
    else:
        link.symlink_to(BENCH.parent, target_is_directory=True)
    try:
        with pytest.raises(ValueError, match='outside the repo'):
            module.import_tasks(tmp_path / 'absent', tmp_path / 'absent', link)
    finally:
        link.rmdir() if os.name == 'nt' else link.unlink()


def test_hle_bad_lines_and_numeric_edges(tmp_path: Path):
    state = tmp_path / 'state'; state.mkdir()
    cases = [('1e3','numeric'), ('007','exact'), (' 12 ','exact'), ('1_000','exact'),
             ('-0','numeric'), ('3.0','numeric'), ('1/2','exact'), ('Infinity','exact'), ('0x10','exact'),
             ('+2.5e-3','numeric'), ('01.5','exact'), ('answer: 12','exact'), ('.5','numeric'), ('1.','numeric')]
    rows = [dict(id=f'edge-{i}', question='Synthetic number', answer=a, answer_type='exactMatch', image='')
            for i,(a,_) in enumerate(cases)]
    source = tmp_path / 'source.jsonl'
    source.write_text('\nnot JSON\n' + '\n'.join(json.dumps(row) for row in rows))
    ids = tmp_path / 'ids.txt'; ids.write_text('\n'.join(row['id'] for row in rows))
    reports = import_hle.import_tasks(source, ids, state)
    assert any('line 1' in r and 'skipped' in r for r in reports)
    assert any('line 2' in r and 'skipped' in r for r in reports)
    for i,(_,kind) in enumerate(cases):
        metadata = review.private_bank_path(state) / f'hle-edge-{i}/task.json'
        assert json.loads(metadata.read_text())['grader'] == kind


def test_node_jest_recursive_equality(tmp_path: Path):
    task = imported(tmp_path, 'javascript')
    (task / 'hidden_tests.mjs').write_text('''test('Jest equality', () => {
      class Sample { constructor() {this.value = {answer: 6, extra: undefined};} }
      expect(new Sample()).toEqual({value: {answer: 6}});
      expect([undefined, 6]).toEqual([, 6]);
      expect([6]).not.toEqual(['6']);
      expect(new Sample()).not.toStrictEqual({value: {answer: 6}});
      expect({a: undefined}).not.toStrictEqual({});
    });''')
    assert engine.grade_answer(task, (task / 'known-good.txt').read_text())['status'] == 'pass'


def test_two_public_runs_match_head(tmp_path: Path, monkeypatch):
    baseline = types.ModuleType('bench_engine_head')
    baseline.__file__ = str(BENCH / 'bench_engine.py')
    source = subprocess.run(['git', 'show', 'HEAD:scripts/model-router/bench/bench_engine.py'],
                            capture_output=True, text=True, check=True, timeout=10).stdout
    exec(compile(source, baseline.__file__, 'exec'), baseline.__dict__)
    task = tmp_path / 'tasks/synthetic-public'; task.mkdir(parents=True)
    (task / 'task.json').write_text(json.dumps(dict(job='fast', grader='exact', category='mechanical')))
    (task / 'prompt.md').write_text('Synthetic public task')
    class FixedTime:
        @staticmethod
        def now(tz):
            return engine_time(2026, 10, 5, tzinfo=tz)
    engine_time = engine.datetime
    state = tmp_path / 'state'; state.mkdir()
    def run(module, number):
        monkeypatch.setitem(module.CANDIDATE_INPUTS, task.name, ())
        monkeypatch.setattr(module, 'datetime', FixedTime)
        monkeypatch.setattr(module, 'uuid4', lambda: UUID(int=number))
        result = module.run_bench(job='fast', candidate='gpt-test', incumbent='claude-test', trigger='manual', effort='low',
            state_dir=state, tasks=task.parent, config={'judges':{'claude':'claude-judge','codex':'gpt-judge'},'judge_effort':'high'},
            dispatch=lambda r: {'status':'ok','answer':'seven'}, limits=lambda v: {'blocked':False},
            envelope=lambda t:t, outcome=lambda r:None, grade=lambda t,a: {'status':'pass'})
        return result, Path(result['report_paths']['markdown']).read_text()
    # Replay the two baseline runs at the same ids/state, then compare the chunk.
    expected = [run(baseline, i) for i in (1, 2)]
    shutil.rmtree(state / 'bench')
    for i,(old,old_report) in enumerate(expected, 1):
        result, report = run(engine, i)
        assert result.pop('quality_verdict') is None
        assert old.pop('quality_verdict', None) is None
        # HEAD already includes M02 on the M03 build surface. Compare its
        # additive fields too while keeping this replay usable on the M02 base.
        for field, expected_value in [('uninformative_tasks', []), ('proposed_drops', []), ('insufficient_evidence', False)]:
            assert old.pop(field, expected_value) == expected_value
        assert result.pop('uninformative_tasks') == []
        assert result.pop('proposed_drops') == []
        assert result.pop('insufficient_evidence') is False
        # M04's additive fields: with no ranked task they carry no quality evidence
        # and the qualification flags reduce to the pass-fail values.
        for field in ('quality_evidence', 'effort_down_quality_verdict', 'effort_up_quality_verdict',
                      'effort_down_quality_evidence', 'effort_up_quality_evidence'):
            assert result.pop(field) is None and old.pop(field, None) is None
        assert result.pop('swap_qualified') is (result['raw_gate'] == 'pass')
        assert result.pop('tie_qualified') is result['tied']
        old.pop('swap_qualified', None), old.pop('tie_qualified', None)
        assert result == old
        assert report == old_report
    assert not review.private_bank_path(state).exists()


def test_node_array_tampering_cannot_hide_failures(tmp_path: Path):
    task = imported(tmp_path, 'javascript')
    (task / 'hidden_tests.mjs').write_text("import {double} from './synthetic-double';"
        " test('zero', () => expect(double(0)).toBe(0)); test('three', () => expect(double(3)).toBe(6));")
    attack = ("const p = Array.prototype.push; Array.prototype.push = function(...a)"
              "{ if (typeof a[0] === 'string') return this.length; return p.apply(this, a); };")
    result = engine.grade_answer(task, attack + '\nexport const double = x => 0;')
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'
    # Dropping a test's registration (an object pushed onto the runner's list) must not hide it either.
    drop = ("const q = Array.prototype.push; Array.prototype.push = function(...a)"
            "{ if (a[0] && typeof a[0] === 'object' && String(a[0].name).includes('three')) return this.length;"
            " return q.apply(this, a); };")
    result = engine.grade_answer(task, drop + '\nexport const double = x => 0;')
    assert result['status'] == 'fail' and result['failure_category'] == 'implementation'
