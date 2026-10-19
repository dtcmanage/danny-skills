"""Observed marker regressions; fixtures never invoke a model or alert transport."""
from __future__ import annotations
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import re
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'measure-resume-bootstrap.py'
spec = importlib.util.spec_from_file_location('measurement', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BootstrapTests(unittest.TestCase):
    def test_both_hosts(self) -> None:
        for host in ('claude', 'codex'):
            with self.subTest(host=host):
                result = module.measure_transcript(Path(__file__).parent / 'fixtures' / f'bootstrap-{host}.jsonl')
                self.assertEqual(result['baseline_tokens'], 89111)
                self.assertEqual(result['host_overhead_tokens'], 57000)
                self.assertEqual(result['coordinator_added_tokens'], 32111)

    def test_missing_first_usage_falls_back(self) -> None:
        rows = [
            {'type':'assistant','message':{'content':[]}},
            {'type':'assistant','message':{'usage':{'input_tokens':89111},'content':[{'type':'tool_use','id':'mark','input':{'command':'pwsh -File dt-job.ps1 -Verb mark-bootstrap'}}]}},
            {'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'mark','content':'{"baseline_tokens":89111}'}]}}
        ]
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'missing.jsonl'
            path.write_text(''.join(json.dumps(row)+'\n' for row in rows), encoding='utf-8')
            result = module.measure_transcript(path)
        self.assertIsNone(result['host_overhead_tokens'])
        self.assertEqual(result['coordinator_added_tokens'], 89111)
        self.assertIn('unavailable', result['bootstrap_measurement'])

    def test_failed_marker_and_prompt_mentions_do_not_count(self) -> None:
        rows = [
            {'type':'user','message':{'content':'Run dt-job.ps1 mark-bootstrap'}},
            {'type':'assistant','message':{'content':[{'type':'tool_use','id':'mark','input':{'command':'pwsh -File dt-job.ps1 mark-bootstrap'}}]}},
            {'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'mark','is_error':True,'content':'{"baseline_tokens":89111}'}]}}
        ]
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'failed.jsonl'
            path.write_text(''.join(json.dumps(row)+'\n' for row in rows), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'No successful'):
                module.measure_transcript(path)

    def test_cli_added_token_boundary(self) -> None:
        for host in ('claude', 'codex'):
            source = (Path(__file__).parent / 'fixtures' / f'bootstrap-{host}.jsonl').read_text()
            for added in (49999, 50000, 50001):
                with self.subTest(host=host, added=added), tempfile.TemporaryDirectory() as folder:
                    path = Path(folder) / 'gate.jsonl'
                    path.write_text(source.replace('89111', str(57000 + added)), encoding='utf-8')
                    check = subprocess.run([sys.executable, str(SCRIPT), '--transcript', str(path)], capture_output=True, text=True)
                    self.assertEqual(check.returncode, 0 if added < 50000 else 1, check.stderr)
                    result = json.loads(check.stdout)
                    self.assertEqual(result['coordinator_added_tokens'], added)
                    self.assertEqual(result['host_overhead_tokens'], 57000)
                    self.assertEqual(result['baseline_tokens'], 57000 + added)

    def test_codex_command_execution_and_unknown_first_usage(self) -> None:
        for first in ({'last_token_usage': {'input_tokens': 57000}}, {'last_token_usage': None}):
            with self.subTest(first=first), tempfile.TemporaryDirectory() as folder:
                rows = [
                    {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': first}},
                    {'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                        'type': 'CommandExecution', 'command': ['pwsh', '-Verb mark-bootstrap'],
                        'exit_code': 0, 'aggregated_output': '{"baseline_tokens":89111}'}}}
                ]
                path = Path(folder) / 'events.jsonl'
                path.write_text(''.join(json.dumps(row)+'\n' for row in rows), encoding='utf-8')
                result = module.measure_transcript(path)
                self.assertEqual(result['coordinator_added_tokens'], 32111 if first['last_token_usage'] else 89111)

    def test_documented_script_anchors(self) -> None:
        root = SCRIPT.parents[3]
        docs = list(root.glob('skills/*/SKILL.md')) + list(root.glob('skills/*/references/**/*.md')) + list(root.glob('references/**/*.md'))
        for path in docs:
            text = path.read_text(encoding='utf-8')
            relative = path.relative_to(root).parts
            skill = root / 'skills' / relative[1] if relative[0] == 'skills' else None
            for match in re.finditer(r'(?<![\w/<>-])(?:skills/[\w-]+/)?scripts/[\w./-]+', text):
                target = match[0]
                if (root / target).is_file() or (skill and (skill / target).is_file()):
                    self.fail(f'{path.relative_to(root)} contains unanchored existing script {target}')
            if path.name == 'SKILL.md' and ('<skill>/' in text or '<danny-skills>/' in text):
                self.assertEqual(text.count('`<danny-skills>` is the repo root two levels above'), 1, str(path))

if __name__ == '__main__':
    unittest.main()
