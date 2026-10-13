"""Deterministic screenshot stand-in for engine tests with synthetic judges."""
from __future__ import annotations

import base64
from pathlib import Path


def fake_renderer(task: Path, answer: str, png: Path) -> dict[str, str]:
    # A fixed one-pixel PNG: these tests judge mocked responses, not browser pixels.
    png.write_bytes(base64.b64decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII='))
    return {'status': 'ok', 'path': str(png)}
