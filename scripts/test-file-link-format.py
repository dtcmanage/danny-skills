"""Regression checks for the shared local-file-path output contract (backticked absolute paths)."""

from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path

from markdown_it import MarkdownIt


def _code_span(path: str, line: int | None = None) -> str:
    target = f"{path}:{line}" if line is not None else path
    return f"`{target}`"


def _rendered_code(markdown: str) -> str:
    rendered = MarkdownIt("commonmark").render(markdown)
    match = re.findall(r"<code>(.*?)</code>", rendered)
    if len(match) != 1:
        raise AssertionError(f"Expected one code span, got {match!r}")
    return html.unescape(match[0])


def _assert_round_trip(path: str, line: int | None = None) -> None:
    expected = f"{path}:{line}" if line is not None else path
    markdown = f"Saved at {_code_span(path, line)}."
    actual = _rendered_code(markdown)
    if actual != expected:
        raise AssertionError(
            f"Rendered path changed: expected {expected!r}, got {actual!r}; markdown={markdown!r}"
        )
    if "<a " in MarkdownIt("commonmark").render(markdown):
        raise AssertionError(f"Backticked path rendered as a link: {markdown!r}")


def _instruction_files(repo_root: Path) -> list[Path]:
    files = [repo_root / "references" / "conventions.md"]
    files.extend((repo_root / "skills").glob("*/SKILL.md"))
    files.extend((repo_root / "skills").glob("*/references/*.md"))
    files.append(repo_root / "references" / "skill-template" / "SKILL.md")
    return files


def _assert_no_contradictory_guidance(repo_root: Path) -> None:
    forbidden = (
        re.compile(r"bare absolute (?:Windows )?path", re.IGNORECASE),
        re.compile(r"plain Windows absolute paths with backslashes", re.IGNORECASE),
        re.compile(r"No markdown wrappers around the path", re.IGNORECASE),
        re.compile(r"make the filename a Markdown link", re.IGNORECASE),
    )
    failures: list[str] = []
    for path in _instruction_files(repo_root):
        text = path.read_text(encoding="utf-8")
        for pattern in forbidden:
            if pattern.search(text):
                failures.append(f"{path.relative_to(repo_root)}: {pattern.pattern}")
    if failures:
        raise AssertionError("Contradictory path guidance remains:\n" + "\n".join(failures))


def _assert_artifact_producers_inherit_contract(repo_root: Path) -> None:
    required = (
        repo_root / "skills" / "dt-handoff" / "SKILL.md",
        repo_root / "skills" / "dt-plan" / "SKILL.md",
        repo_root / "skills" / "dt-build" / "SKILL.md",
        repo_root / "skills" / "dt-pipeline" / "SKILL.md",
        repo_root / "skills" / "dt-writing-draft" / "SKILL.md",
        repo_root / "skills" / "dt-writing-edit" / "SKILL.md",
    )
    for path in required:
        text = path.read_text(encoding="utf-8")
        if "../../references/conventions.md" not in text:
            raise AssertionError(f"Artifact producer does not inherit conventions: {path}")


def _assert_existing_target(path: Path) -> Path:
    resolved = path.resolve(strict=True)
    rendered = _rendered_code(f"Saved at {_code_span(str(resolved))}.")
    if Path(rendered).resolve(strict=True) != resolved:
        raise AssertionError(f"Rendered existing-file path changed: {rendered!s} != {resolved!s}")
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--existing-path",
        type=Path,
        help="Existing file whose rendered path must resolve byte-for-byte.",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    cases = (
        "/home/danny/Claude/_Claude-Workspace/project/artifact.md",
        "/home/danny/Claude/_Claude-Workspace/TCM Website/project/artifact.md",
        "/home/danny/Claude/workspace/project/file_name.md",
        r"D:\Claude\_Claude-Workspace\TCM Website\project\file_name.md",
    )
    for case in cases:
        _assert_round_trip(case)
    _assert_round_trip(
        "/home/danny/Claude/_Claude-Workspace/TCM Website/project/file_name.md", line=42
    )
    _assert_no_contradictory_guidance(repo_root)
    _assert_artifact_producers_inherit_contract(repo_root)
    if args.existing_path is not None:
        resolved = _assert_existing_target(args.existing_path)
        print(f"existing-target: {resolved}")

    print("PASS: CommonMark local-file-link contract and artifact producers verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
