"""Render real state output from the isolated resume fixture, including every split part."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('resume_fixture', Path(__file__).with_name('test-resume-bootstrap.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
case = module.StateDigestTests()
try:
    case.setUp()
    # Exercise real multipart reconstruction within the 10k reserve, not just a tiny header.
    (case.run / 'build-plan.md').write_text('Scope: local source changes only. Never deploy.\n' * 500)
    result = case.digest()
    if result.returncode:
        raise RuntimeError(result.stderr)
    sys.stdout.write(result.stdout)
    if result.stdout.startswith('{'):
        plan = json.loads(result.stdout)
        for part in range(1, plan['parts'] + 1):
            result = case.digest('-Part', str(part), '-ExpectSha', plan['sha256'])
            if result.returncode:
                raise RuntimeError(result.stderr)
            sys.stdout.write(result.stdout)
finally:
    case.doCleanups()
