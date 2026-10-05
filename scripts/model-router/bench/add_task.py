"""Add a problem and expected answer to an explicitly supplied private bench bank."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import shutil

from bench_engine import grade_answer
from review import TASKS, private_bank_path, task_folders


REPO = Path(__file__).resolve().parents[3]


def main_checkout() -> Path:
    pointer = REPO / '.git'
    if pointer.is_file():
        git_dir = Path(pointer.read_text(encoding='utf-8').strip().removeprefix('gitdir: '))
        if not git_dir.is_absolute():
            git_dir = REPO / git_dir
        common = (git_dir / 'commondir').read_text(encoding='utf-8').strip()
        return (git_dir / common).resolve().parent
    return REPO


def validate_state(state: Path) -> Path:
    state = state.resolve()
    if any(state.is_relative_to(root) for root in (REPO, main_checkout())):
        raise ValueError("State folder must be outside the repo")
    if not state.is_dir():
        raise ValueError(f'State directory does not exist: {state}')
    if state.name.casefold() == 'bench':
        raise ValueError(f'Pass the router state directory, not its bench folder: {state}')
    return state


def add_task(*, state: Path, problem: Path, answer: Path, job: str,
             grader: str, difficulty: str, task_id: str | None = None, category: str | None = None,
             solution_file: str | None = None, hidden_test: Path | None = None,
             bad_answer: Path | None = None, exact_text: bool = False) -> Path:
    state = validate_state(state)
    if job not in {'fast', 'coder', 'deep-thinker', 'writer'} or grader not in {'exact', 'numeric', 'pytest', 'nodetest'} or difficulty not in {'standard', 'hard'}:
        raise ValueError('Invalid job, grader or difficulty')
    if grader in {'pytest', 'nodetest'} and (hidden_test is None or solution_file is None
            or Path(solution_file).name != solution_file or not re.fullmatch(r'[a-zA-Z0-9_-]+\.(py|js)', solution_file)):
        raise ValueError('Code task requires a solution filename and hidden test')
    slug = task_id if task_id is not None else re.sub(r'[^a-z0-9]+', '-', problem.stem.lower()).strip('-')
    if not slug or not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', slug):
        raise ValueError('Task id must be a lowercase slug')
    private = private_bank_path(state)
    if slug.casefold() in {name.casefold() for name in task_folders(TASKS, private)}:
        raise ValueError(f'Duplicate task id in in-repo or private bank: {slug}')
    prompt = problem.read_text(encoding='utf-8')
    expected = answer.read_text(encoding='utf-8')
    try:
        parsed = json.loads(expected)
        suffix = 'json'
    except ValueError:
        parsed, suffix = None, 'txt'
    if exact_text and grader == 'exact':
        suffix = 'txt'
    if grader == 'numeric':
        if not isinstance(parsed, dict) or not parsed or any(
            type(value) not in (int, float) or not math.isfinite(value)
            for wanted in parsed.values() for value in (wanted if isinstance(wanted, list) else [wanted])
        ):
            raise ValueError('Numeric answer must be a JSON object of finite numbers or number lists')
    task = private / slug
    task.parent.mkdir(parents=True, exist_ok=True)
    task.mkdir()  # Exclusive creation: never overwrite an existing task.
    (task / 'golden').mkdir()
    (task / 'prompt.md').write_text(prompt, encoding='utf-8')
    (task / f'golden/answer.{suffix}').write_text(expected, encoding='utf-8')
    (task / 'known-good.txt').write_text(expected, encoding='utf-8')
    metadata = {'id': slug, 'category': {'fast': 'mechanical', 'coder': 'routine-coding',
                'deep-thinker': 'math' if grader == 'numeric' else 'analysis', 'writer': 'writing'}[job],
                'job': job, 'grader': grader, 'difficulty': difficulty,
                'dimension_framework': 'provisional'}
    if category is not None:
        metadata['category'] = category
    if grader in {'pytest', 'nodetest'}:
        metadata['solution_file'] = solution_file
        shutil.copyfile(hidden_test, task / ('hidden_tests.py' if grader == 'pytest' else 'hidden_tests.mjs'))
    if bad_answer is not None:
        shutil.copyfile(bad_answer, task / 'known-bad.txt')
    (task / 'task.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    result = grade_answer(task, (task / 'known-good.txt').read_text(encoding='utf-8'))
    if result['status'] != 'pass':
        shutil.rmtree(task)
        raise ValueError(f'Known-good answer did not pass the {grader} grader; task removed: {slug} ({result["status"]})')
    if bad_answer is not None:
        result = grade_answer(task, (task / 'known-bad.txt').read_text(encoding='utf-8'))
        if result['status'] != 'fail':
            shutil.rmtree(task)
            raise ValueError(f'Known-bad answer did not fail the {grader} grader; task removed: {slug} ({result["status"]})')
    return task


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, required=True, help='existing router state directory (the folder containing bench/)')
    parser.add_argument('--problem', type=Path, required=True)
    parser.add_argument('--answer', type=Path, required=True)
    parser.add_argument('--job', choices=('fast', 'coder', 'deep-thinker', 'writer'), required=True)
    parser.add_argument('--grader', choices=('exact', 'numeric'), required=True,
                        help='plain-text exact uses whitespace-trimmed equality; JSON uses the existing exact or numeric grader')
    parser.add_argument('--difficulty', choices=('standard', 'hard'), required=True)
    parser.add_argument('--id', dest='task_id')
    args = parser.parse_args()
    try:
        task = add_task(**vars(args))
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(task)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
