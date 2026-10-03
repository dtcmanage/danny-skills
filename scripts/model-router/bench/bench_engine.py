"""Bench comparison and outer grading boundary; dispatch is supplied by the host.

StateDir is the router state root. No implicit live state, alerts, or approvals.
"""
from __future__ import annotations

from datetime import datetime, timezone
from fractions import Fraction
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
from typing import Any, Callable
from uuid import uuid4

from review import Review, bank_hash

BENCH = Path(__file__).resolve().parent
JOBS = {'fast', 'coder', 'deep-thinker', 'writer', 'illustrator'}
TRIGGERS = {'new-model', 'research', 'drift', 'manual'}

# Explicit input contract: fixture directories also contain grader-only data.
CANDIDATE_INPUTS = {
    'mechanical-extract-table': ('input.json', 'document.txt'),
    'mechanical-rename-sweep': ('input.json',),
    'routine-coding-endpoint': ('input.json', 'app.py'),
    'complex-coding-ledger': ('input.json',),
    'ui-frontend-card': ('input.json',),
    'code-review-planted': (),  # The source is already in prompt.md.
    'math-return-series': ('input.json',),
    'analysis-ddq-gaps': ('input.json',),
    'planning-migration': ('input.json',),
    'deep-research-vendor': ('input.json',),
    'writing-letter-section': ('input.json',),
    'pelican': ('input.json',),
}


def candidate_prompt(task: Path) -> str:
    prompt = (task / 'prompt.md').read_text(encoding='utf-8')
    for name in CANDIDATE_INPUTS[task.name]:
        fixture = task / 'fixtures' / name
        prompt += '\n\nSynthetic fixture fixtures/' + name + ':\n' + fixture.read_text(encoding='utf-8')
    return prompt


def answer_body(answer: str) -> str:
    answer = re.sub(r'^\s*\[\d{2}:\d{2}:\d{2}\]\s*', '', answer).strip()
    match = re.fullmatch(r'```[^\n]*\n(.*?)\n```', answer, re.S)
    return match.group(1) if match else answer


def grade_answer(task: Path, answer: str, *, timeout: float = 30) -> dict[str, Any]:
    """Always execute the repo grader in a fresh directory with scrubbed env."""
    env = {k: v for k, v in os.environ.items() if k.upper() not in
           {'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'CLAUDE_CONFIG_DIR'}}
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    with tempfile.TemporaryDirectory(prefix='router-bench-rep-') as directory:
        work = Path(directory)
        env.update({key: directory for key in ('TMP', 'TEMP', 'TMPDIR')})
        evidence = work / 'answer.txt'
        evidence.write_text(answer_body(answer), encoding='utf-8', newline='')
        try:
            process = subprocess.Popen(
                [sys.executable, str(BENCH / 'grader-runner.py'), str(task.resolve()), str(evidence)],
                cwd=work, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, start_new_session=os.name != 'nt')
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                # Kill descendants while the root PID is still alive. Killing
                # just the outer runner leaves pytest/Node holding temp files.
                if os.name == 'nt':
                    subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                                   capture_output=True, timeout=5, check=True)
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
            if process.returncode:
                raise RuntimeError(stderr)
            return json.loads(stdout)
        except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as error:
            return {'status': 'unknown', 'failure_category': 'environment', 'detail': str(error)}


def judge_score(rubric: dict[str, Any], answer: str) -> tuple[float, dict[str, int]]:
    scores = json.loads(answer_body(answer))['scores']
    ids = {line['id'] for line in rubric['lines']}
    if not isinstance(scores, dict) or set(scores) != ids or not ids:
        raise ValueError('Missing or unexpected rubric scores')
    if any(type(v) is not int or v not in (0, 1) for v in scores.values()):
        raise ValueError('Rubric scores must be binary integers')
    return sum(scores.values()) / len(ids), scores


def compare(candidate: dict[str, Any], incumbent: dict[str, Any]) -> str:
    if candidate['unknown'] or incumbent['unknown']:
        return 'unknown'
    return 'pass' if candidate['passed'] >= incumbent['passed'] - 1 else 'fail'


def baseline_key(job: str, model: str, effort: str | None, digest: str,
                 judges: dict[str, str] | None, judge_effort: str | None = None) -> str:
    identity = [job, model, effort, digest, judges]
    if judges is not None:
        identity.append(judge_effort)
    return json.dumps(identity, sort_keys=True, separators=(',', ':'))


def run_bench(*, job: str, candidate: str, incumbent: str, trigger: str,
              effort: str | None, state_dir: Path, tasks: Path,
              config: dict[str, Any], dispatch: Callable[[dict[str, Any]], dict[str, Any]],
              limits: Callable[[str], dict[str, Any]], envelope: Callable[[str], str],
              outcome: Callable[[dict[str, Any]], None],
              grade: Callable[[Path, str], dict[str, Any]] = grade_answer,
              prices: dict[str, Any] | None = None) -> dict[str, Any]:
    if job not in JOBS or trigger not in TRIGGERS:
        raise ValueError('Invalid job or trigger; monthly is unsupported')
    if set(config.get('judges', {})) != {'claude', 'codex'} or len(set(config['judges'].values())) != 2:
        raise ValueError('Exactly two distinct configured vendor judges required')
    if (job != 'illustrator' and effort not in {'low', 'medium', 'high'}) or (
        job == 'illustrator' and effort is not None):
        raise ValueError('Explicit approved effort required (illustrator uses null)')
    judge_effort = config.get('judge_effort')
    if not isinstance(judge_effort, str) or judge_effort not in {'low', 'medium', 'high'}:
        raise ValueError('Explicit configured judge_effort must be low, medium or high')
    state = state_dir / 'bench'
    review = Review(tasks, state)
    approval = review.refresh()
    digest = bank_hash(tasks)
    selected = [p.parent for p in sorted(tasks.glob('*/task.json'))
                if json.loads(p.read_text(encoding='utf-8'))['job'] == job]
    if not selected:
        raise ValueError('No tasks for job')
    shadow = len(review.ids) != 12 or not approval['approved']
    run = state / 'runs' / uuid4().hex
    run.mkdir(parents=True)
    rows: list[dict[str, Any]] = []
    calls: list[dict[str, Any]] = []
    judges = config['judges']

    def call(model: str, level: str | None, prompt: str, purpose: str) -> dict[str, Any]:
        vendor = 'claude' if model.startswith('claude-') else 'codex'
        try:
            quota = limits(vendor)
        except Exception as error:
            quota = {'blocked': True, 'detail': str(error), 'measurement': 'unavailable'}
        if quota.get('blocked'):
            result = {'status': 'unknown', 'failure_category': 'environment',
                      'detail': 'quota blocked', 'quota': quota}
        elif model == 'gpt-image-2':
            result = {'status': 'unknown', 'failure_category': 'environment',
                      'detail': 'Image invocation unsupported by text CLI', 'quota': quota}
        else:
            try:
                result = dispatch({'model': model, 'vendor': vendor, 'effort': level,
                                   'prompt': prompt, 'purpose': purpose})
                if not isinstance(result, dict) or (result.get('status') == 'ok' and not isinstance(result.get('answer'), str)):
                    raise ValueError('Invalid dispatch payload')
            except Exception as error:
                result = {'status': 'unknown', 'failure_category': 'environment', 'detail': str(error)}
            result = {**result, 'quota': quota}
        calls.append({'model': model, 'vendor': vendor, 'purpose': purpose, **result, 'effort': level})
        return result

    def table(model: str, level: str | None, side: str) -> dict[str, Any]:
        results = []
        for task in selected:
            metadata = json.loads((task / 'task.json').read_text(encoding='utf-8'))
            if task.name == 'pelican' and trigger != 'manual':
                results.append({'task_id': task.name, 'status': 'ungraded', 'reps': [],
                                'detail': 'Artifact-only pelican runs on manual/full-bank scope'})
                continue
            reps = []
            count = 1 if task.name == 'pelican' else 3
            for rep in range(1, count + 1):
                for attempt in (1, 2):
                    row = {'source': 'bench', 'trigger': trigger, 'job': job, 'effort': level,
                           'model': model, 'side': side, 'task_bank_sha256': digest,
                           'task_id': task.name, 'rep': rep, 'attempt': attempt,
                           'timestamp': datetime.now(timezone.utc).isoformat()}
                    try:
                        prompt = candidate_prompt(task)
                    except OSError as error:
                        response = {'status': 'unknown', 'failure_category': 'environment',
                                    'detail': 'Required candidate input unavailable: ' + str(error)}
                    else:
                        response = call(model, level, prompt, 'answer')
                    row['response'] = response
                    status = response.get('status', 'unknown')
                    if status == 'ok':
                        answer = answer_body(response['answer'])
                        evidence = run / f'{side}-{task.name}-{rep}-{attempt}.txt'
                        evidence.write_text(answer, encoding='utf-8')
                        row['answer_path'] = str(evidence)
                        if task.name == 'pelican':
                            artifact = evidence.with_suffix('.svg')
                            artifact.write_text(answer, encoding='utf-8')
                            row['artifact_path'] = str(artifact)
                            status = 'ungraded'
                        elif metadata['grader'] == 'rubric':
                            rubric = json.loads((task / 'golden/rubric.json').read_text(encoding='utf-8'))
                            prompt = ((task / 'judge-prompt.md').read_text(encoding='utf-8') + '\n'
                                      + 'Original request and supplied input evidence:\n' + candidate_prompt(task) + '\n'
                                      + json.dumps(rubric) + '\n' + envelope(answer))
                            scores = []
                            status = 'pass'
                            for judge in judges.values():
                                judged = call(judge, judge_effort, prompt, 'judge')
                                record = {'model': judge, 'effort': judge_effort, 'response': judged,
                                          'weight': 2 if model in judges.values() and judge != model else 1}
                                try:
                                    if judged.get('status') != 'ok':
                                        raise ValueError('Judge unavailable')
                                    record['score'], record['scores'] = judge_score(rubric, judged['answer'])
                                except (ValueError, KeyError, TypeError) as error:
                                    status = 'unknown'
                                    record['error'] = str(error)
                                scores.append(record)
                            row['judge_scores'] = scores
                            row['judge_models'] = list(judges.values())
                            row['judge_effort'] = judge_effort
                            if status != 'unknown':
                                # Preserve exact binary-score fractions through weighting and threshold.
                                average = sum(Fraction(sum(s['scores'].values()), len(s['scores'])) * s['weight']
                                              for s in scores) / sum(s['weight'] for s in scores)
                                row['judge_average'] = float(average)
                                row['judge_disagreement'] = abs(scores[0]['score'] - scores[1]['score'])
                                row['disagreement'] = row['judge_disagreement'] > config.get('judge_disagreement_threshold', .3)
                                status = 'pass' if average >= Fraction(str(rubric.get('threshold', config.get('rubric_threshold', .8)))) else 'fail'
                        else:
                            graded = grade(task, answer)
                            row['grading'] = graded
                            status = graded['status']
                    row.update(status=status, passed=status == 'pass', unknown=status == 'unknown',
                               failure_category='environment' if status == 'unknown' else
                               ('implementation' if status == 'fail' else None))
                    rows.append(row)
                    outcome(row)
                    if status != 'unknown' or attempt == 2:
                        break
                reps.append(status)
            task_status = 'unknown' if 'unknown' in reps else ('ungraded' if count == 1 else
                          ('pass' if reps.count('pass') >= 2 else 'fail'))
            results.append({'task_id': task.name, 'status': task_status, 'reps': reps})
        return {'model': model, 'effort': level, 'tasks': results,
                'passed': sum(t['status'] == 'pass' for t in results),
                'unknown': sum(t['status'] == 'unknown' for t in results)}

    candidate_table = table(candidate, effort, 'candidate')
    incumbent_table = candidate_table if job == 'illustrator' and incumbent == candidate else table(incumbent, effort, 'incumbent')
    down = {'medium': 'low', 'high': 'medium'}.get(effort)
    down_table = table(incumbent, down, 'effort-down') if down else None
    raw_gate = compare(candidate_table, incumbent_table)
    if job == 'illustrator' and raw_gate != 'unknown':
        raw_gate = 'advisory'
    result = {'gate': 'unknown' if raw_gate == 'unknown' else ('advisory' if shadow or job in {'writer', 'illustrator'} else raw_gate),
              'raw_gate': raw_gate, 'shadow': shadow, 'job': job, 'trigger': trigger,
              'task_bank_sha256': digest, 'judge_pair': judges, 'judge_effort': judge_effort,
              'dimension_framework': config.get('dimension_framework', 'provisional'),
              'candidate': candidate_table, 'incumbent': incumbent_table,
              'effort_down': down_table,
              'effort_down_qualified': down_table is not None and compare(down_table, incumbent_table) == 'pass',
              'shortfall_tasks': max(0, incumbent_table['passed'] - candidate_table['passed']),
              'outcomes': rows, 'calls': calls, 'baseline_drops': [],
              'report_paths': {'json': str(run / 'report.json'), 'markdown': str(run / 'report.md'),
                               'golden_review': str(review.artifact_path)}}
    baseline_path = state / 'baseline.json'
    baselines = json.loads(baseline_path.read_text(encoding='utf-8')) if baseline_path.exists() else {}
    rubric_present = any((t / 'golden/rubric.json').exists() for t in selected)
    for score_table in [candidate_table, incumbent_table] + ([down_table] if down_table else []):
        if score_table['unknown'] or job == 'illustrator':
            continue
        key = baseline_key(job, score_table['model'], score_table['effort'], digest, judges if rubric_present else None,
                           judge_effort if rubric_present else None)
        previous = baselines.get(key)
        if previous is not None and score_table['passed'] < previous['passed']:
            result['baseline_drops'].append({'model': score_table['model'], 'effort': score_table['effort'],
                                             'before': previous['passed'], 'after': score_table['passed']})
        if previous is None:
            baselines[key] = score_table
    temporary = baseline_path.with_suffix('.tmp')
    temporary.write_text(json.dumps(baselines, indent=2), encoding='utf-8')
    temporary.replace(baseline_path)
    result['price_recommendation'] = None
    if prices and candidate_table['passed'] == incumbent_table['passed'] and raw_gate == 'pass':
        def price(model: str) -> float | None:
            models = prices.get('models', {})
            rates = models.get(model, models.get(re.sub(r'-\d{8}$', '', model), {})).get('prices_usd_per_mtok', {})
            return rates['input'] + rates['output'] if all(type(rates.get(k)) in (int, float) and math.isfinite(rates[k]) and rates[k] >= 0 for k in ('input', 'output')) else None
        cp, ip = price(candidate), price(incumbent)
        if cp is not None and ip is not None:
            result['price_recommendation'] = candidate if cp < ip else incumbent
    result['telemetry'] = summarize_calls(calls, prices or {})
    lines = [f"Gate: {result['gate']} (raw: {raw_gate}); shadow: {shadow}",
             f"Shortfall: {result['shortfall_tasks']} task(s)",
             f"Price recommendation: {result['price_recommendation']}",
             f"Effort-down qualified: {result['effort_down_qualified']}",
             f"Judge pair: {json.dumps(judges)}; effort: {judge_effort}", f"Bank: {digest}"]
    for label, score_table in [('Candidate', candidate_table), ('Incumbent', incumbent_table), ('Effort-down', down_table)]:
        if score_table:
            lines += ['', f"{label}: {score_table['model']} / {score_table['effort']}",
                      '| Task | Status | Reps |', '| --- | --- | --- |']
            lines += [f"| {t['task_id']} | {t['status']} | {', '.join(t['reps'])} |" for t in score_table['tasks']]
    lines += ['', '| Vendor | Measured calls | Partial calls | Unmeasured calls | Priced subtotal USD | Unpriced calls | Quota before / after |', '| --- | --- | --- | --- | --- | --- | --- |']
    for vendor, data in result['telemetry'].items():
        lines.append(f"| {vendor} | {data['measured_calls']} | {data['partial_calls']} | {data['unmeasured_calls']} | {data['priced_subtotal_usd']} | {data['unpriced_calls']} | {data['quota_before']} / {data['quota_after']} |")
    lines += ['', 'Disagreements: ' + json.dumps([{'task': r['task_id'], 'rep': r['rep'], 'scores': r['judge_scores']} for r in rows if r.get('disagreement')]),
              'Baseline drops: ' + json.dumps(result['baseline_drops']), 'Artifacts: ' + json.dumps(result['report_paths'])]
    (run / 'report.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    (run / 'report.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return result


def summarize_calls(calls: list[dict[str, Any]], prices: dict[str, Any]) -> dict[str, Any]:
    totals = {}
    for vendor in ('claude', 'codex'):
        lane = [c for c in calls if c['vendor'] == vendor]
        data = {'measured_calls': 0, 'unmeasured_calls': 0, 'partial_calls': 0, 'unpriced_calls': 0,
                'priced_subtotal_usd': 0.0, 'tokens': {},
                'quota_before': lane[0]['quota'] if lane else None,
                'quota_after': lane[-1].get('quota_after') if lane else None}
        for call in lane:
            usage = call.get('usage')
            if (not isinstance(usage, dict) or not {'input', 'output'} <= usage.keys()
                    or any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in usage.values())):
                data['unmeasured_calls'] += 1
                continue
            data['partial_calls' if call.get('usage_partial', call.get('status') == 'unknown') else 'measured_calls'] += 1
            model = call.get('resolved_model', call['model'])
            models = prices.get('models', {})
            entry = models.get(model, models.get(re.sub(r'-\d{8}$', '', model), {}))
            rates = entry.get('prices_usd_per_mtok', {})
            cost, priced = 0.0, True
            for key, value in usage.items():
                data['tokens'][key] = data['tokens'].get(key, 0) + value
                rate = None if vendor == 'claude' and key == 'cache_write' else rates.get(key)
                if value and (type(rate) not in (int, float) or not math.isfinite(rate) or rate < 0):
                    priced = False
                elif type(rate) in (int, float) and math.isfinite(rate) and rate >= 0:
                    cost += value * rate / 1_000_000
            if priced:
                data['priced_subtotal_usd'] += cost
            else:
                data['unpriced_calls'] += 1
        totals[vendor] = data
    return totals


def main() -> None:
    """Line IPC: all production callbacks execute in the PowerShell host."""
    arguments = json.loads(sys.stdin.readline())
    def callback(operation: str, payload: Any) -> Any:
        print(json.dumps({'operation': operation, 'payload': payload}), flush=True)
        reply = json.loads(sys.stdin.readline())
        if 'error' in reply:
            raise RuntimeError(reply['error'])
        return reply['value']
    arguments['state_dir'] = Path(arguments['state_dir'])
    arguments['tasks'] = Path(arguments['tasks'])
    timeout = arguments.pop('grader_timeout', 30)
    result = run_bench(**arguments, dispatch=lambda p: callback('dispatch', p),
                       limits=lambda v: callback('limits', v), envelope=lambda a: callback('envelope', a),
                       outcome=lambda r: callback('outcome', r),
                       grade=lambda t, a: grade_answer(t, a, timeout=timeout))
    print(json.dumps({'operation': 'result', 'payload': result}), flush=True)


if __name__ == '__main__':
    main()
