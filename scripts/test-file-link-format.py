"""Regression checks for the shared Markdown local-file-link contract."""

from __future__ import annotations

import argparse
import html
import re
import sys
from html.parser import HTMLParser
from pathlib import Path, PureWindowsPath
from urllib.parse import unquote

from markdown_it import MarkdownIt


class _LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hrefs: list[str] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        if tag != "a":
            return
        for name, value in attrs:
            if name == "href" and value is not None:
                self.hrefs.append(html.unescape(value))


def _destination(path: str, line: int | None = None) -> str:
    normalized = path.replace("\\", "/")
    return f"{normalized}:{line}" if line is not None else normalized


def _link(path: str, label: str | None = None, line: int | None = None) -> str:
    destination = _destination(path, line)
    display = label or PureWindowsPath(path).name
    if line is not None:
        display = f"{display}:{line}"
    wrapped = f"<{destination}>" if " " in destination else destination
    return f"[{display}]({wrapped})"


def _rendered_href(markdown: str) -> str:
    rendered = MarkdownIt("commonmark").render(markdown)
    parser = _LinkParser()
    parser.feed(rendered)
    if len(parser.hrefs) != 1:
        raise AssertionError(f"Expected one rendered link, got {parser.hrefs!r}")
    return unquote(parser.hrefs[0])


def _assert_round_trip(path: str, line: int | None = None) -> None:
    expected = _destination(path, line)
    markdown = _link(path, line=line)
    actual = _rendered_href(markdown)
    if actual != expected:
        raise AssertionError(
            f"Rendered destination changed: expected {expected!r}, got {actual!r}; "
            f"markdown={markdown!r}"
        )
    if "\\" in actual:
        raise AssertionError(f"Rendered destination contains a backslash: {actual!r}")
    if " " in path and "(<" not in markdown:
        raise AssertionError(f"Spaced destination is not angle-bracketed: {markdown!r}")


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
    windows_path = str(resolved)
    rendered = _rendered_href(_link(windows_path))
    rendered_path = Path(rendered.replace("/", "\\"))
    if rendered_path.resolve(strict=True) != resolved:
        raise AssertionError(
            f"Rendered existing-file target changed: {rendered_path!s} != {resolved!s}"
        )
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--existing-path",
        type=Path,
        help="Existing Windows file whose rendered destination must resolve byte-for-byte.",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    cases = (
        r"D:\Claude\_Claude-Workspace\project\artifact.md",
        r"D:\Claude\_Claude-Workspace\TCM Website\project\artifact.md",
        r"D:\Claude\workspace\project\file_name.md",
    )
    for case in cases:
        _assert_round_trip(case)
    _assert_round_trip(
        r"D:\Claude\_Claude-Workspace\TCM Website\project\file_name.md", line=42
    )
    _assert_no_contradictory_guidance(repo_root)
    _assert_artifact_producers_inherit_contract(repo_root)
    if args.existing_path is not None:
        resolved = _assert_existing_target(args.existing_path)
        print(f"existing-target: {_destination(str(resolved))}")

    print("PASS: CommonMark local-file-link contract and artifact producers verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
