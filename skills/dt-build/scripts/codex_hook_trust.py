"""Edit only the requested Codex trust table; validate before atomic replacement.

Python 3.11+ (tomllib) is required. Keep the text editor in sync with the workspace
read-guard's ensure_hook.py, which must also work without this skill installed.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import tomllib
from pathlib import Path


def table_starts(text: str, *, assignments: bool = False) -> list[int]:
    """Find line-start table headers outside comments and all TOML string forms."""
    starts = []
    i = 0
    line_start = True
    depth = 0
    while i < len(text):
        char = text[i]
        if char in " \t\r":
            i += 1
            continue
        if char == "\n":
            line_start = True
            i += 1
            continue
        if line_start and depth == 0 and (char == "[" or (assignments and char != "#")):
            starts.append(i)
        line_start = False
        if char == "#":
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
        elif char in "\"'":
            quote = char
            triple = text.startswith(quote * 3, i)
            i += 3 if triple else 1
            while i < len(text):
                if quote == '"' and text[i] == "\\":
                    i += 2
                elif text[i] == quote:
                    end = i + 1
                    while triple and end < len(text) and text[end] == quote:
                        end += 1
                    if not triple or end - i >= 3:
                        i = end
                        break
                    i = end
                else:
                    i += 1
        else:
            if char in "[{":
                depth += 1
            elif char in "]}":
                depth -= 1
            i += 1
    return starts


def updated_trust(text: str, key: str, digest: str) -> str:
    """Collapse equivalent headers, keeping the supplied (current/newest) hash.

    Parse each header with TOML itself, including quoted parent keys and escapes.
    Retain non-hash fields from all matching tables; ambiguous duplicates of those
    fields fail final validation rather than silently discarding configuration.
    """
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("unexpected hook hash")
    newline = "\r\n" if "\r\n" in text else "\n"
    starts = table_starts(text) + [len(text)]
    edits = []
    bodies = []
    for start, end in zip(starts, starts[1:]):
        line_end = text.find("\n", start, end)
        line_end = end if line_end < 0 else line_end + 1
        header = text[start:line_end]
        try:
            parsed = tomllib.loads(header)
        except tomllib.TOMLDecodeError:
            continue  # Invalid input is refused by the final full-document parse.
        if parsed != {"hooks": {"state": {key: {}}}}:
            continue
        body = text[line_end:end]
        # Parse each complete table before editing. Do not treat a hash-looking
        # line inside a multiline string as an assignment.
        tomllib.loads(header + body)
        hash_doc = tomllib.loads(body)
        if "trusted_hash" in hash_doc:
            offsets = table_starts(body, assignments=True)
            for at, stop in reversed(list(zip(offsets, offsets[1:] + [len(body)]))):
                assignment = body[at:stop]
                if "trusted_hash" in tomllib.loads(assignment):
                    # Keep trailing comments/blank lines. The value may itself
                    # be a multiline TOML string, so stop at its first parseable
                    # complete line rather than using a line-based substitution.
                    value_end = at
                    for line in assignment.splitlines(keepends=True):
                        value_end += len(line)
                        try:
                            tomllib.loads(body[at:value_end])
                        except tomllib.TOMLDecodeError:
                            continue
                        break
                    body = body[:at] + body[value_end:]
        bodies.append(body)
        edits.append((start, end, header))
    value = 'trusted_hash = ' + json.dumps(digest) + newline
    if edits:
        # Keep the last spelling/location, remove earlier table declarations.
        replacement = edits[-1][2].rstrip("\r\n") + newline + value
        replacement += ''.join(part if part.endswith("\n") or not part else part + newline for part in bodies)
        for index, (start, end, _) in reversed(list(enumerate(edits))):
            text = text[:start] + (replacement if index == len(edits) - 1 else '') + text[end:]
    else:
        text = text.rstrip("\r\n") + newline * 2 + '[hooks.state.' + json.dumps(key, ensure_ascii=False) + ']' + newline + value
    tomllib.loads(text)
    return text


def set_codex_trust(config: Path, key: str, digest: str) -> None:
    text = config.read_bytes().decode("utf-8") if config.exists() else ""
    out = updated_trust(text, key, digest)
    fd, temp = tempfile.mkstemp(prefix=".codex-trust-", suffix=".tmp", dir=config.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(out)
        # Validate the exact bytes that will replace the original.
        with open(temp, "rb") as handle:
            tomllib.load(handle)
        os.replace(temp, config)
    finally:
        Path(temp).unlink(missing_ok=True)


if __name__ == "__main__":
    request = json.load(sys.stdin)
    set_codex_trust(Path(request["config"]), request["key"], request["hash"])
