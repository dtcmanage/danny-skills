"""Import selected text-only exact-answer questions from a local HLE export."""
from __future__ import annotations
import argparse
import json
import math
import re
from pathlib import Path
import tempfile
from add_task import add_task, validate_state


def import_tasks(source: Path, ids: Path, state: Path) -> list[str]:
    state = validate_state(state)
    wanted = list(dict.fromkeys(line.strip() for line in ids.read_text(encoding='utf-8').splitlines() if line.strip()))
    rows = {}
    reports = []
    with source.open(encoding='utf-8') as stream:
        for line_number, line in enumerate(stream, 1):
            try:
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError('row must be an object')
            except ValueError as error:
                reports.append(f'line {line_number}: skipped: invalid JSON: {error}')
                continue
            if str(row.get('id')) in wanted:
                rows[str(row['id'])] = row
    for question_id in wanted:
        row = rows.get(question_id)
        reason = ('id not found' if row is None else 'answer_type is not exactMatch' if row.get('answer_type') != 'exactMatch'
                  else 'image is not empty' if row.get('image') != '' else None)
        if reason:
            reports.append(f'{question_id}: skipped: {reason}')
            continue
        answer = str(row['answer'])
        try:
            number = float(answer)
            numeric = bool(re.fullmatch(r'[+-]?(?:(?:0|[1-9][0-9]*)(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?', answer)) and math.isfinite(number)
        except ValueError:
            numeric = False
        try:
            with tempfile.TemporaryDirectory(prefix='router-import-') as directory:
                problem, expected = Path(directory) / 'problem.md', Path(directory) / 'answer.txt'
                problem.write_text(str(row['question']) + ('\nReturn a JSON object with the numeric answer under "answer".' if numeric else '\nReturn only the exact answer.'), encoding='utf-8')
                expected.write_text(json.dumps({'answer': number}) if numeric else answer, encoding='utf-8')
                task = add_task(state=state, problem=problem, answer=expected, job='deep-thinker',
                    grader='numeric' if numeric else 'exact', difficulty='hard', category='math', task_id='hle-' + question_id, exact_text=not numeric)
            reports.append(f'{question_id}: imported {task.name}')
        except (OSError, ValueError) as error:
            reports.append(f'{question_id}: skipped: {error}')
    return reports


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'ids', 'state'):
        parser.add_argument('--' + name, type=Path, required=True)
    try:
        reports = import_tasks(**vars(parser.parse_args()))
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print('\n'.join(reports))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
