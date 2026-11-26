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
import os

SCRIPT = Path(__file__).resolve().parents[1] / 'measure-resume-bootstrap.py'
spec = importlib.util.spec_from_file_location('measurement', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BootstrapTests(unittest.TestCase):
    def test_rendered_budget_and_sections(self) -> None:
        result = module.measure_plan(Path(__file__).parent / 'fixtures' / 'resume-bootstrap-budget.json', SCRIPT.parents[3])
        self.assertTrue(result['pass'], result)
        entry = result['components'][-1]
        self.assertLessEqual(entry['chars'], 20000)
        self.assertTrue(any('Authority read contract' in row['section'] for row in entry['sections']))
        state = result['components'][0]
        self.assertGreater(state['observed_chars'], 22000)
        self.assertGreater(state['observed_tokens'], 0)
        self.assertLessEqual(state['observed_tokens'], state['tokens'])

    def test_budget_fails_when_measured_state_exceeds_reserve(self) -> None:
        manifest = Path(__file__).parent / 'fixtures' / 'resume-bootstrap-budget.json'
        plan = json.loads(manifest.read_text())
        plan['measured_components'][0]['tokens'] = 1
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'budget.json'
            path.write_text(json.dumps(plan))
            self.assertFalse(module.measure_plan(path, SCRIPT.parents[3])['pass'])

    def test_entry_ceiling_both_hosts(self) -> None:
        for host in ('claude', 'codex'):
            with self.subTest(host=host):
                result = subprocess.run(['pwsh', '-NoProfile', '-File', str(SCRIPT.parent / 'read-coordinator-rulebook.ps1'), '-CoordinatorHost', host], check=True, capture_output=True, text=True)
                self.assertLessEqual(len(result.stdout), 20000)

    def test_launcher_orders_only_bootstrap_reads_before_marker(self) -> None:
        launcher = (SCRIPT.parent / 'launch-managed-coordinator.ps1').read_text()
        prompt = launcher.split('$prompt = @"',1)[1].split('"@',1)[0]
        self.assertLess(prompt.index('read-coordinator-rulebook.ps1'), prompt.index('read-coordinator-state.ps1'))
        self.assertLess(prompt.index('read-coordinator-state.ps1'), prompt.index('-Verb mark-bootstrap'))
        self.assertIn('Only after the marker load on-demand sections', prompt)
        self.assertIn('system instructions, entry, state digest, mark-bootstrap', prompt)
        self.assertIn('Do not cat build-state, roadmap, design or canonical policy docs', prompt)
        self.assertIn('Never run dt-job resume, approve, delegate or hold.', prompt)

    def test_policy_and_execution_load_only_on_demand(self) -> None:
        entry = subprocess.run(['pwsh','-NoProfile','-File',str(SCRIPT.parent/'read-coordinator-rulebook.ps1')],check=True,capture_output=True,text=True).stdout
        for body in ('6. Execute milestones', '## Frontmatter fields', '## The `_log.md` friction-note convention'):
            self.assertNotIn(body, entry)
        self.assertIn('git-workflow.md before actual git actions', entry)
        self.assertIn('model-routing.md before dispatch', entry)
        self.assertIn('build-process.md before starting a new build or close-out', entry)
        execution = subprocess.run(['pwsh','-NoProfile','-File',str(SCRIPT.parent/'read-coordinator-rulebook.ps1'),'-Section','execution'],check=True,capture_output=True,text=True).stdout
        self.assertIn('6. Execute milestones', execution)
        self.assertIn('## Carry on', execution)

    def test_single_entry_added_budget(self) -> None:
        manifest = Path(__file__).parent / 'fixtures' / 'resume-bootstrap-budget.json'
        plan = json.loads(manifest.read_text())
        self.assertEqual(plan['target_tokens'], 20000)
        self.assertIn('coordinator-added', plan['budget_scope'])
        self.assertEqual(plan['repo_reads'], [])
        self.assertEqual(len(plan['rendered_reads']), 1)
        self.assertIn('read-coordinator-rulebook.ps1', ' '.join(plan['rendered_reads'][0]['command']))
        self.assertTrue(any(item['tokens'] >= 6000 and 'approvals' in item['source'] for item in plan['measured_components']))

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

class StateDigestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / 'run'
        self.run.mkdir()
        self.state = self.root / '_build-state-finance.md'
        self.roadmap = self.root / 'roadmap.md'
        self.design = self.root / 'plan-draft.md'
        self.design.write_text('Scope: local source changes only. Implementation details deferred.\n')
        self.boundary = self.root / 'current-boundary.md'
        self.boundary.write_text('Current boundary: never push or deploy.\n')
        self.roadmap.write_text('## Milestones\n\n| id | name |\n| --- | --- |\n| M01 | old |\n| M02 | current |\n| M03 | future |\n\n## Other\nimplementation detail deferred\n')
        self.checkpoint = f'run_status: runnable\nlast_consumed_event_seq: 0\ncurrent_milestone: M02\nroadmap_path: {self.roadmap}\ndesign_path: {self.design}\nBoundary: local only; never deploy.\n'
        self.state.write_text(self.checkpoint)
        self.env = dict(os.environ, DT_BUILD_STATE_DIR=str(self.root / 'registry'))
        for key in ('DT_BUILD_COORDINATOR_ID', 'DT_JOB_ID'):
            self.env.pop(key, None)
        result = self.call('dt-job.ps1', 'register-run', '-Managed', '-PinnedHost', 'codex', '-Json', '-RunFolder', str(self.run), '-RunId', 'digest-test', '-BuildStatePath', str(self.state))
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.run / 'coordinator.lease').write_text('{"coordinator_id":"fixture","launched_by":"watcher","released_utc":null}')
        (self.run / 'build-state.md').write_text('Run restriction: no production write.\n')
        (self.run / 'build-plan.md').write_text('Plan restriction: source only.\n')
        (self.run / 'approvals.json').write_text('{"awaiting":{"operation":"ship"},"approvals":[{"operation":"local","seq":7}]}')
        (self.run / 'operator-notes.json').write_text('[]')

    def call(self, script: str, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(['pwsh','-NoProfile','-File',str(SCRIPT.parent / script),*args], env=self.env, capture_output=True, text=True)

    def digest(self, *args: str) -> subprocess.CompletedProcess:
        return self.call('read-coordinator-state.ps1','-RunFolder',str(self.run),'-RunId','digest-test','-BuildStatePath',str(self.state),'-CoordinatorId','fixture',*args)

    def test_ai90_pipeline_template_comment_is_not_a_checkpoint_original(self) -> None:
        template = (SCRIPT.parents[2] / 'dt-pipeline/templates/build-state-template.md').read_text()
        comment = re.search(r'<!--.*?-->', template, re.S).group()
        self.state.write_text(comment + '\n' + self.checkpoint)
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(comment, result.stdout)
        manifest = json.loads((self.run / 'authority-digest.json').read_text())
        self.assertNotIn(str(self.root / '_build-state.md'), [row['path'] for row in manifest['originals']])
        # The same literal outside the provenance comment is still an operative original.
        self.state.write_text(comment + '\n' + self.checkpoint + 'Read governing original: `_build-state.md` IN FULL.\n')
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AUTHORITY_CHECKPOINT_HASH', result.stderr)
        result = self.call('build-authority-digest.ps1', '-RunFolder', str(self.run), '-BuildStatePath', str(self.state))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AUTHORITY_MISSING', result.stderr)
        self.assertIn('_build-state.md', result.stderr)

    def test_ai90_remote_plan_evidence_is_not_local_authority(self) -> None:
        self.design.write_text('Evidence: /etc/cloudflared/config.yml on CT105.\n'
                               'Evidence: `/etc/cloudflared/config.yml` on CT105.\n'
                               'CT105: `/etc/cloudflared/config.yml`.\n')
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.run / 'authority-digest.json').read_text())
        self.assertNotIn('/etc/cloudflared/config.yml', [row['path'] for row in manifest['originals']])
        self.assertIn(str(self.design), [row['path'] for row in manifest['originals']])
        self.assertIn('remote_host_evidence', (self.run / 'authority-digest.md').read_text())

    def test_ai90_missing_local_authority_in_plan_stays_required(self) -> None:
        missing = self.root / 'missing-local-original.md'
        # Remote evidence on another line cannot waive a local original, even with a host mention.
        self.design.write_text('Evidence: `/etc/cloudflared/config.yml` on CT105.\n'
                               f'Read governing original: `{missing}` IN FULL (for CT105).\n')
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AUTHORITY_MISSING', result.stderr)
        plain_error = re.sub(r'\s+', ' ', re.sub(r'\x1b\[[0-9;]*m', '', result.stderr))
        self.assertIn(missing.name, plain_error)
        missing.write_text('Only local source edits; never deploy.\n')
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.run / 'authority-digest.json').read_text())
        self.assertIn(str(missing), [row['path'] for row in manifest['originals']])
        missing.unlink()
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AUTHORITY_MISSING', result.stderr)

    def populate_long_run(self) -> None:
        dims = json.loads((Path(__file__).parent / 'fixtures/resume-long-run.json').read_text())
        self.roadmap.write_text(self.roadmap.read_text() + '\n## Historical implementation\n' + 'Deferred implementation detail.\n' * (dims['roadmap_chars'] // 32))
        for name in ('build-state.md', 'build-plan.md'):
            with (self.run / name).open('a') as handle:
                handle.write(f'\nroadmap_path: {self.roadmap}\n')
        (self.run / 'operator-notes.json').write_text(json.dumps({'notes': [{'id': 'n-standing', 'text': 'Standing restriction: local only. ' * (dims['standing_notes_chars'] // 32)}]}))
        (self.run / 'approvals.json').write_text(json.dumps({'awaiting': {'operation': 'device-test'}, 'approvals': [{'operation': 'local', 'seq': i, 'scope': 'Local only, never deploy.'} for i in range(dims['approvals_chars'] // 80)]}))
        jobs = self.run / 'jobs'
        jobs.mkdir(exist_ok=True)
        for i in range(1, dims['completed_jobs'] + 1):
            (jobs / f'j-{i:04d}.json').write_text(json.dumps({'job_id': f'j-{i:04d}', 'status': 'succeeded', 'kind': 'worker', 'spec': 'historical spec ' * 200}))
        (jobs / 'j-0039.json').write_text(json.dumps({'job_id': 'j-0039', 'status': 'running', 'kind': 'worker', 'depends_on': [], 'status_reason': None}))
        (jobs / 'j-0040.json').write_text(json.dumps({'job_id': 'j-0040', 'status': 'blocked', 'kind': 'worker', 'depends_on': ['j-0039'], 'status_reason': 'waiting for dependency'}))
        (jobs / 'events.jsonl').write_text(''.join(json.dumps({'seq': i, 'type': 'completed', 'job_id': f'j-{i % 38 + 1:04d}'}) + '\n' for i in range(1, dims['events'] + 1)))
        (self.run / 'acceptance-rows.jsonl').write_text('Historical acceptance evidence.\n' * (dims['acceptance_chars'] // 32))
        (self.run / 'build-decision-log.md').write_text('Historical decision evidence.\n' * (dims['decision_chars'] // 30))

    def test_long_run_history_is_deferred_without_duplicate_authority(self) -> None:
        self.populate_long_run()
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('Historical acceptance evidence.', result.stdout)
        self.assertNotIn('Deferred implementation detail.', result.stdout)
        self.assertNotIn('historical spec', result.stdout)
        original = result.stdout.split('## Mandatory original (full): ' + str(self.run / 'operator-notes.json'), 1)[1]
        self.assertEqual(original.count('Standing restriction: local only.'), 5335 // 32)
        self.assertIn('device-test', result.stdout)
        self.assertIn('"seq":156', result.stdout)
        self.assertNotIn('"seq":150,', result.stdout)
        self.assertIn('"status":"running"', result.stdout)
        self.assertIn('"status":"blocked"', result.stdout)
        self.assertIn('waiting for dependency', result.stdout)

    def test_complete_authority_compact_navigation_no_dispatch(self) -> None:
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        for body in (self.checkpoint, 'Run restriction: no production write.', 'Plan restriction: source only.', '"operation":"ship"', '| M02 | current |'):
            self.assertIn(body, result.stdout)
        self.assertNotIn('| M01 | old |', result.stdout)
        self.assertNotIn('| M03 | future |', result.stdout)
        self.assertNotIn('implementation detail deferred', result.stdout)
        self.assertNotIn('## Mandatory original (full): ' + str(self.design), result.stdout)
        self.assertEqual(self.state.read_text(), self.checkpoint)
        self.assertFalse((self.run / 'jobs' / 'events.jsonl').exists())

    def test_identity_and_stale_authority_fail_closed(self) -> None:
        self.assertEqual(self.digest().returncode, 0)
        (self.run / 'build-plan.md').write_text('Changed restriction: never ship.\n')
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        (self.run / 'coordinator.lease').write_text('{"coordinator_id":"intruder","launched_by":"watcher"}')
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DT_RESUME_IDENTITY', result.stderr)

    def test_legacy_manifest_migrates_only_unchanged_sources(self) -> None:
        legacy = self.call('build-authority-digest.ps1','-RunFolder',str(self.run),'-BuildStatePath',str(self.state),'-LegacyArtifactKinds')
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        before = json.loads((self.run/'authority-digest.json').read_text())
        self.assertTrue(all(r['kind'] == 'boundary' for r in before['originals'] if r['path'] in (str(self.design), str(self.roadmap))))
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        after = json.loads((self.run/'authority-digest.json').read_text())
        self.assertEqual([(r['path'],r['sha256'],r['bytes']) for r in before['originals']],[(r['path'],r['sha256'],r['bytes']) for r in after['originals']])
        self.assertNotIn(str(self.roadmap), after['mandatory_paths'])
        self.assertNotIn(str(self.design), after['mandatory_paths'])
        legacy = self.call('build-authority-digest.ps1','-RunFolder',str(self.run),'-BuildStatePath',str(self.state),'-LegacyArtifactKinds')
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        pinned = (self.run/'authority-digest.json').read_bytes()
        self.design.write_text('Changed scope: remote writes now allowed.\n')
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertEqual((self.run/'authority-digest.json').read_bytes(), pinned)

    def test_large_sources_are_split_without_omitting_authority(self) -> None:
        body = 'Complete mandatory restriction.\n' * 1200
        (self.run / 'build-plan.md').write_text(body)
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan['state'], 'mandatory_reads_pending')
        parts = []
        for part in range(1, plan['parts'] + 1):
            result = self.digest('-Part', str(part), '-ExpectSha', plan['sha256'])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(plan['sha256'], result.stdout.splitlines()[0])
            self.assertLess(len(result.stdout), 22500)
            parts.append(result.stdout.split('\n',1)[1].rstrip('\n') if part == plan['parts'] else result.stdout.split('\n',1)[1][:-1])
        self.assertIn(body.rstrip(), ''.join(parts))
        self.assertNotEqual(self.digest('-Part',str(plan['parts'] + 1)).returncode, 0)
        self.assertNotEqual(self.digest('-Part', '1').returncode, 0)
        self.state.write_text(self.checkpoint.replace('current_milestone: M02', 'current_milestone: M03'))
        changed = self.digest('-Part', '2', '-ExpectSha', plan['sha256'])
        self.assertNotEqual(changed.returncode, 0)
        self.assertEqual(changed.stdout, '')
        self.assertIn('DT_RESUME_CHANGED', changed.stderr)

    def test_live_milestone_ids_and_annotations(self) -> None:
        for milestone in ('M2.1', 'M02a', 'phase-build', 'M03 (M02 done)'):
            with self.subTest(milestone=milestone):
                self.state.write_text(self.checkpoint.replace('current_milestone: M02', f'current_milestone: {milestone}'))
                key = milestone.split()[0]
                self.roadmap.write_text(f'## Milestones\n| ID | name |\n| --- | --- |\n| {key} | current |\n| M02 | unrelated |\n')
                for file in self.run.glob('authority-digest.*'):
                    file.unlink()
                result = self.digest()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('| ID | name |', result.stdout)
                self.assertIn(f'| {key} | current |', result.stdout)
                if 'M02' not in milestone:
                    self.assertNotIn('| M02 | unrelated |', result.stdout)

    def test_free_text_multiple_exact_milestones(self) -> None:
        for cursor in ('M02 (awaiting device test) and M03 (builder j-0024 running)', 'M03 password stop, then M02'):
            self.state.write_text(self.checkpoint.replace('current_milestone: M02', f'current_milestone: {cursor}'))
            result = self.digest()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('| M02 | current |', result.stdout)
            self.assertIn('| M03 | future |', result.stdout)
        for cursor in ('M020', 'M02a', 'prefix-M02', 'm02'):
            self.state.write_text(self.checkpoint.replace('current_milestone: M02', f'current_milestone: {cursor}'))
            result = self.digest()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('current_milestone: M01', result.stderr)
            self.assertIn('Write', result.stderr)

    def test_previous_lifecycle_manifest_migrates_only_verified_bytes(self) -> None:
        self.populate_long_run()
        self.state.write_text(self.checkpoint + 'status_line: running\n')
        legacy = self.call('build-authority-digest.ps1', '-RunFolder', str(self.run), '-BuildStatePath', str(self.state), '-LegacyLifecycleLocators')
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        before = json.loads((self.run / 'authority-digest.json').read_text())
        self.assertIn(str(self.roadmap), before['mandatory_paths'])
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        after = json.loads((self.run / 'authority-digest.json').read_text())
        self.assertNotIn(str(self.roadmap), after['mandatory_paths'])
        self.assertEqual(before['originals'], after['originals'])
        self.state.write_text(self.checkpoint + 'status_line: completed\n')
        self.assertEqual(self.digest().returncode, 0)

    def test_snapshot_survives_lifecycle_changes_but_rejects_authority(self) -> None:
        (self.run / 'build-plan.md').write_text('Mandatory restriction.\n' * 1400)
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        first = self.digest('-Part', '1', '-ExpectSha', plan['sha256'])
        self.state.write_text(self.checkpoint + 'status_line: job running\n')
        (self.run / 'jobs').mkdir(exist_ok=True)
        (self.run / 'jobs' / 'events.jsonl').write_text('{"seq":9,"type":"running","job_id":"j-0024"}\n')
        again = self.digest('-Part', '1', '-ExpectSha', plan['sha256'])
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(first.stdout, again.stdout)
        (self.run / 'operator-notes.json').write_text('{"notes":[{"text":"Never merge"}]}')
        changed = self.digest('-Part', '2', '-ExpectSha', plan['sha256'])
        self.assertNotEqual(changed.returncode, 0)
        self.assertEqual(changed.stdout, '')

    def multipart_plan(self) -> dict:
        (self.run / 'build-plan.md').write_text('Mandatory restriction.\n' * 1400)
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def shadow_reader(self, mutation: str = '', omit_mandatory: bool = False) -> Path:
        shadow = self.root / 'scripts'
        shadow.mkdir(exist_ok=True)
        reader = (SCRIPT.parent / 'read-coordinator-state.ps1').read_text()
        marker = '# Recheck after collecting sources;'
        (shadow / 'read-coordinator-state.ps1').write_text(reader.replace(marker, mutation + '\n' + marker))
        (shadow / 'dt-job.ps1').write_text(f". '{SCRIPT.parent / 'dt-job.ps1'}' @args\n")
        for name in ('read-resume-record.ps1', 'build-authority-digest.ps1', 'verify-authority-digest.ps1', 'read-authority-digest.ps1', 'read-authority-original.ps1'):
            body = f"& '{SCRIPT.parent / name}' @args\n"
            if omit_mandatory and name == 'verify-authority-digest.ps1':
                body = f"$v = & '{SCRIPT.parent / name}' @args | ConvertFrom-Json\n$v.mandatory_paths = @($v.mandatory_paths | Where-Object {{ (Split-Path -Leaf $_) -notin @('approvals.json','operator-notes.json') }})\n$v | ConvertTo-Json -Depth 10 -Compress\n"
            (shadow / name).write_text(body)
        return shadow / 'read-coordinator-state.ps1'

    def shadow_digest(self, path: Path) -> subprocess.CompletedProcess:
        return self.call(str(path), '-RunFolder', str(self.run), '-RunId', 'digest-test', '-BuildStatePath', str(self.state), '-CoordinatorId', 'fixture')

    def test_every_part_rechecks_lease_registration_and_stopped_state(self) -> None:
        plan = self.multipart_plan()
        # Exercise after an earlier part was served, where ownership could have changed.
        self.assertEqual(self.digest('-Part', '1', '-ExpectSha', plan['sha256']).returncode, 0)
        lease = self.run / 'coordinator.lease'
        original = lease.read_text()
        for update in ({'coordinator_id': 'intruder', 'launched_by': 'watcher'},
                       {'coordinator_id': 'fixture', 'launched_by': 'watcher', 'released_utc': '2026-11-24T12:00:00Z'}):
            lease.write_text(json.dumps(update))
            result = self.digest('-Part', '2', '-ExpectSha', plan['sha256'])
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            self.assertIn('DT_RESUME_IDENTITY', result.stderr)
        lease.write_text(original)
        self.state.write_text(self.checkpoint.replace('runnable', 'awaiting_danny'))
        result = self.digest('-Part', '2', '-ExpectSha', plan['sha256'])
        self.assertIn('DT_RESUME_STOPPED', result.stderr)
        self.state.write_text(self.checkpoint)
        unregister = self.call('dt-job.ps1', 'unregister-run', '-RunFolder', str(self.run))
        self.assertEqual(unregister.returncode, 0, unregister.stderr)
        result = self.digest('-Part', '2', '-ExpectSha', plan['sha256'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('DT_RESUME_IDENTITY', result.stderr)

    def test_multipart_discovers_new_authority_and_rebuilt_manifest(self) -> None:
        for name, body in (('operator-notes.json', '{"notes":[{"text":"Never merge"}]}'),
                           ('approvals.json', '{"awaiting":{"operation":"new-stop"},"approvals":[]}')):
            with self.subTest(name=name):
                (self.run / name).unlink()
                for file in self.run.glob('authority-digest.*'):
                    file.unlink()
                plan = self.multipart_plan()
                (self.run / name).write_text(body)
                result = self.digest('-Part', '1', '-ExpectSha', plan['sha256'])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                rebuild = self.call('build-authority-digest.ps1', '-RunFolder', str(self.run), '-BuildStatePath', str(self.state))
                self.assertEqual(rebuild.returncode, 0, rebuild.stderr)
                result = self.digest('-Part', '1', '-ExpectSha', plan['sha256'])
                self.assertIn('DT_RESUME_CHANGED', result.stderr)

    def test_authority_record_present_without_mandatory_paths(self) -> None:
        (self.run / 'context-wall.json').write_text('{"reason":"context stop needs review"}')
        (self.run / 'operator-notes.json').write_text('{"notes":[{"text":"Never merge"}]}')
        result = self.shadow_digest(self.shadow_reader(omit_mandatory=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        for text in ('Never merge', 'context stop needs review', '"operation":"ship"'):
            self.assertIn(text, result.stdout)

    def test_full_record_recheck_catches_unpinned_context_wall(self) -> None:
        path = self.shadow_reader(f"[IO.File]::WriteAllText('{self.run / 'context-wall.json'}', '{{\"reason\":\"new context stop\"}}')")
        result = self.shadow_digest(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('DT_RESUME_CHANGED: run record', result.stderr)

    def test_final_part_refreshes_jobs_events_and_deletes_private_snapshot(self) -> None:
        plan = self.multipart_plan()
        cache = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'dt-build/coordinator-snapshots'
        snapshots = list(cache.glob(f"*-{plan['sha256']}.json"))
        self.assertEqual(len(snapshots), 1)
        if os.name != 'nt':
            self.assertEqual(cache.stat().st_mode & 0o777, 0o700)
        jobs = self.run / 'jobs'
        jobs.mkdir(exist_ok=True)
        (jobs / 'j-0041.json').write_text(json.dumps({'job_id':'j-0041','status':'blocked','kind':'worker','status_reason':'fresh stop','depends_on':[]}))
        (jobs / 'events.jsonl').write_text('{"seq":99,"type":"blocked","job_id":"j-0041"}\n')
        result = self.digest('-Part', str(plan['parts']), '-ExpectSha', plan['sha256'])
        self.assertEqual(result.returncode, 0, result.stderr)
        tail = result.stdout.split('## Final-part refreshed evidence', 1)[1]
        self.assertIn('fresh stop', tail)
        self.assertIn('"seq":99', tail)
        self.assertFalse(snapshots[0].exists())

    def test_multipart_rechecks_unpinned_context_wall(self) -> None:
        plan = self.multipart_plan()
        (self.run / 'context-wall.json').write_text('{"reason":"new context stop"}')
        result = self.digest('-Part', '1', '-ExpectSha', plan['sha256'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_empty_milestones_report_actionable_error(self) -> None:
        self.roadmap.write_text('## Milestones\n| id | name |\n| --- | --- |\n')
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DT_RESUME_MILESTONE: Milestones table has no data rows', result.stderr)

    def test_lifecycle_locator_is_navigation_but_scope_is_mandatory(self) -> None:
        for name in ('build-plan.md', 'build-state.md'):
            (self.run / name).write_text(f'roadmap_path: {self.roadmap}\nRestriction: never deploy.\n')
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('## Mandatory original (full): ' + str(self.roadmap), result.stdout)
        for name in ('build-plan.md', 'build-state.md'):
            (self.run / name).write_text(f'roadmap_path: {self.roadmap}\nScope per design:\n{self.roadmap}\n')
        for file in self.run.glob('authority-digest.*'):
            file.unlink()
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('## Mandatory original (full): ' + str(self.roadmap), result.stdout)

    def test_invalid_and_duplicate_milestones_fail_closed(self) -> None:
        for cursor in ('', '???', 'M02 and M03', 'M02', 'M02\ncurrent_milestone: M03'):
            with self.subTest(cursor=cursor):
                self.state.write_text(self.checkpoint.replace('current_milestone: M02', f'current_milestone: {cursor}'))
                self.roadmap.write_text('## Milestones\n| ID | name |\n| --- | --- |\n| M02 | one |\n| M02 | two |\n')
                for file in self.run.glob('authority-digest.*'):
                    file.unlink()
                result = self.digest()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('DT_RESUME_MILESTONE', result.stderr)

    def test_boundary_reference_on_separate_line_is_mandatory(self) -> None:
        self.boundary.write_text(f'Current boundary: local only.\nScope per the design doc: `{self.design}`\n')
        self.state.write_text(self.checkpoint + f'Current boundary: {self.boundary}\n')
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('## Mandatory original (full): ' + str(self.design), result.stdout)
        self.assertIn('Scope: local source changes only.', result.stdout)

    def test_plan_locator_cannot_reclassify_lifecycle_plan(self) -> None:
        self.state.write_text(self.checkpoint + f'plan_path: {self.run / "build-plan.md"}\n')
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.run / 'authority-digest.json').read_text())
        record = next(r for r in manifest['originals'] if r['path'] == str(self.run / 'build-plan.md'))
        self.assertEqual(record['kind'], 'boundary')
        self.assertIn('Plan restriction: source only.', result.stdout)

    def test_approval_scope_artifact_is_mandatory(self) -> None:
        path = self.run / 'approvals.json'
        approval = json.loads(path.read_text())
        approval['scope_source'] = str(self.design)
        path.write_text(json.dumps(approval))
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('## Mandatory original (full): ' + str(self.design), result.stdout)

    def test_inherited_artifact_cannot_be_deferred(self) -> None:
        stop = self.root / 'stop'
        stop.mkdir()
        for name in ('disposition.md', 'scope.md', 'approval.md'):
            (stop / name).write_text('Local only. Never deploy.\n')
        (stop / 'next-operation-boundary.json').write_text(json.dumps({
            'inherited_authority_sources': [str(self.design)],
            'source_disposition': 'disposition.md', 'scope': 'scope.md',
            'approval_text': 'approval.md', 'required_original_records': 5}))
        self.state.write_text(self.checkpoint + f'STOP={stop}\n')
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('## Mandatory original (full): ' + str(self.design), result.stdout)

    def test_lease_change_during_collection_fails_closed(self) -> None:
        # Instrument only the verifier call boundary in an isolated script copy.
        shadow = self.root / 'scripts'
        shadow.mkdir()
        reader = (SCRIPT.parent / 'read-coordinator-state.ps1').read_text()
        marker = '# Recheck after collecting sources;'
        reader = reader.replace(marker, f"[IO.File]::WriteAllText('{self.run / 'coordinator.lease'}', '{{\"coordinator_id\":\"intruder\",\"launched_by\":\"watcher\"}}')\n{marker}")
        (shadow / 'read-coordinator-state.ps1').write_text(reader)
        (shadow / 'dt-job.ps1').write_text(f". '{SCRIPT.parent / 'dt-job.ps1'}' @args\n")
        for name in ('read-resume-record.ps1', 'build-authority-digest.ps1', 'verify-authority-digest.ps1', 'read-authority-digest.ps1', 'read-authority-original.ps1'):
            (shadow / name).write_text(f"& '{SCRIPT.parent / name}' @args\n")
        result = subprocess.run(['pwsh', '-NoProfile', '-File', str(shadow / 'read-coordinator-state.ps1'), '-RunFolder', str(self.run), '-RunId', 'digest-test', '-BuildStatePath', str(self.state), '-CoordinatorId', 'fixture'], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('DT_RESUME_IDENTITY', result.stderr)

    def test_closed_boundary_cannot_silently_exclude_named_artifact(self) -> None:
        stop = self.root / 'stop'
        stop.mkdir()
        (stop / 'disposition.md').write_text('Local only.\n')
        (stop / 'scope.md').write_text(f'Scope per the design doc:\n`{self.design}`\n')
        (stop / 'approval.md').write_text('Never deploy.\n')
        (stop / 'next-operation-boundary.json').write_text(json.dumps({
            'inherited_authority_sources': [],
            'source_disposition': 'disposition.md', 'scope': 'scope.md',
            'approval_text': 'approval.md', 'required_original_records': 4}))
        self.state.write_text(self.checkpoint + f'STOP={stop}\n')
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('AUTHORITY_ARTIFACT_UNENUMERATED', result.stderr)

    def test_rebuilt_authority_during_collection_cannot_mix_snapshots(self) -> None:
        shadow = self.root / 'scripts'
        shadow.mkdir()
        reader = (SCRIPT.parent / 'read-coordinator-state.ps1').read_text()
        mutation = (
            f"[IO.File]::WriteAllText('{self.run / 'build-plan.md'}', 'Changed restriction: never merge.')\n"
            f"$null = & '{SCRIPT.parent / 'build-authority-digest.ps1'}' -RunFolder $RunFolder -BuildStatePath $BuildStatePath\n"
        )
        reader = reader.replace('# Recheck after collecting sources;', mutation + '# Recheck after collecting sources;')
        (shadow / 'read-coordinator-state.ps1').write_text(reader)
        (shadow / 'dt-job.ps1').write_text(f". '{SCRIPT.parent / 'dt-job.ps1'}' @args\n")
        for name in ('read-resume-record.ps1', 'build-authority-digest.ps1', 'verify-authority-digest.ps1', 'read-authority-digest.ps1', 'read-authority-original.ps1'):
            (shadow / name).write_text(f"& '{SCRIPT.parent / name}' @args\n")
        result = self.call(str(shadow / 'read-coordinator-state.ps1'), '-RunFolder', str(self.run), '-RunId', 'digest-test', '-BuildStatePath', str(self.state), '-CoordinatorId', 'fixture')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('DT_RESUME_CHANGED', result.stderr)

    def test_missing_milestone_fails_closed(self) -> None:
        self.roadmap.write_text('## Milestones\n| id | name |\n| --- | --- |\n| M01 | old |\n')
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DT_RESUME_MILESTONE', result.stderr)

    def test_missing_required_lifecycle_source_fails_closed(self) -> None:
        (self.run / 'build-plan.md').unlink()
        result = self.digest()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DT_RESUME_SOURCE_MISSING', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_explicit_full_roadmap_and_design_reads_are_never_deferred(self) -> None:
        self.state.write_text(self.checkpoint + f'Read IN FULL before bootstrap: {self.roadmap}\nRead IN FULL before bootstrap: {self.design}\n')
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        for original in (self.roadmap, self.design):
            self.assertIn('## Mandatory original (full): ' + str(original), result.stdout)
        self.assertIn('implementation detail deferred', result.stdout)

    def test_current_boundary_is_mandatory_with_artifact_navigation(self) -> None:
        self.state.write_text(self.checkpoint + f'Current boundary: {self.boundary}\n')
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('## Mandatory original (full): ' + str(self.boundary), result.stdout)
        self.assertIn('Current boundary: never push or deploy.', result.stdout)
        self.assertNotIn('## Mandatory original (full): ' + str(self.roadmap), result.stdout)

if __name__ == '__main__':
    unittest.main()
