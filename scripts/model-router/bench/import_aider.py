"""Import selected local Polyglot exercises into the private bank."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import tempfile
from add_task import add_task, validate_state


def import_tasks(source: Path, ids: Path, state: Path) -> list[str]:
    state = validate_state(state)
    reports = []
    for exercise_id in ids.read_text(encoding='utf-8').splitlines():
        exercise_id = exercise_id.strip()
        if not exercise_id:
            continue
        try:
            if not re.fullmatch(r'(python|javascript)/[a-z0-9]+(?:-[a-z0-9]+)*', exercise_id):
                raise ValueError('unsupported language or invalid exercise id')
            language, slug = exercise_id.split('/')
            exercise = source / language / 'exercises/practice' / slug
            files = json.loads((exercise / '.meta/config.json').read_text(encoding='utf-8'))['files']
            def local(name: str) -> Path:
                path = (exercise / name).resolve()
                if not path.is_relative_to(exercise.resolve()):
                    raise ValueError('exercise file outside exercise directory')
                return path
            stub = local(files['solution'][0])
            tests = local(files['test'][0])
            reference = local(files['example'][0])
            instructions = (exercise / '.docs/instructions.md').read_text(encoding='utf-8')
            appendix = exercise / '.docs/instructions.append.md'
            if appendix.exists():
                instructions += '\n' + appendix.read_text(encoding='utf-8')
            with tempfile.TemporaryDirectory(prefix='router-import-') as directory:
                prompt = Path(directory) / 'problem.md'
                prompt.write_text(instructions + '\n\nStub ' + stub.name + ':\n```' + language + '\n'
                    + stub.read_text(encoding='utf-8') + '\n```\nReturn the complete solution file in one fenced block.', encoding='utf-8')
                task = add_task(state=state, problem=prompt, answer=reference, job='coder',
                    grader='pytest' if language == 'python' else 'nodetest', difficulty='hard',
                    category='complex-coding', task_id=f'aider-{language}-{slug}',
                    solution_file=stub.name, hidden_test=tests, bad_answer=stub)
            reports.append(f'{exercise_id}: imported {task.name}')
        except (OSError, ValueError, KeyError, IndexError) as error:
            reports.append(f'{exercise_id}: skipped: {error}')
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
