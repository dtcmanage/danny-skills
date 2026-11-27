"""Disposable Git histories for committed gate reuse (no production services)."""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "resolve-gate-scope.py"
PRODUCER = SCRIPT.with_name("record-gate.py")
SPEC = importlib.util.spec_from_file_location("gate_scope", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
COMMAND = "python3 gate.py; exit $LASTEXITCODE"
CONTRACTS = ["gate.py", "suites.json"]


class GateScopeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="gate scope ")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write(".gitignore", ".dt-build/\n")
        self.write(".ship.json", json.dumps({"gateCommand": COMMAND}))
        self.write("gate.py", "pass\n")
        self.write("suites.json", "{}")
        self.write("old.py", "old\n")
        self.live = self.commit("live-release")
        self.write("checked.py", "checked\n")
        self.gated = self.commit("earlier-successful-gate")
        self.tree = self.git("rev-parse", "HEAD^{tree}")
        self.write("fix.py", "fix\n")
        self.candidate = self.commit("additional-fix")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, name: str, text: str) -> None:
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self, name: str) -> str:
        self.git("add", ".")
        self.git("commit", "-qm", name)
        return self.git("rev-parse", "HEAD")

    def record(self, name: str = "good", **fields: object) -> Path:
        snapshot = dict(sha=self.gated, tree_hash=self.tree, status="")
        gate = dict(sha=self.gated, tree_hash=self.tree, command=COMMAND,
                    result="PASS", exit_code=0, clean=True, scope="release",
                    contract_paths=CONTRACTS, before=snapshot, after=snapshot,
                    contract_snapshot=MODULE.dependency_snapshot(
                        self.repo, self.gated, MODULE.contract_paths(CONTRACTS)))
        gate.update(fields)
        # Unit fixtures describe real committed snapshots; integration cases below
        # obtain all fields exclusively from the executable producer.
        if "sha" in fields and fields.get("result", "PASS") == "PASS":
            gate["before"] = gate["after"] = dict(sha=gate["sha"], tree_hash=gate["tree_hash"], status="")
            gate["contract_snapshot"] = MODULE.dependency_snapshot(
                self.repo, gate["sha"], MODULE.contract_paths(CONTRACTS))
        path = self.repo / ".dt-build" / name / "final-integration.json"
        self.write(str(path.relative_to(self.repo)), json.dumps({"gate": gate}))
        return path

    def resolve(self, **kwargs: object) -> dict:
        return MODULE.resolve_scope(self.repo, COMMAND, "release", CONTRACTS, **kwargs)

    def assertFull(self, result: dict) -> None:
        self.assertTrue(result["full_test"], result)
        self.assertIsNone(result["gate_scope_base"]["sha"])
        self.assertIn("checked.py", result["changed_paths"])

    def test_success_excludes_checked_changes_instead_of_live_release(self) -> None:
        self.record()
        result = self.resolve()
        self.assertEqual(result["gate_scope_base"]["sha"], self.gated)
        self.assertEqual(result["changed_paths"], ["fix.py"])
        # Original failure: a live-release diff reselects the already checked module.
        self.assertIn("checked.py", self.git("diff", "--name-only", self.live).splitlines())

    def test_nearest_ancestor_ignores_timestamp_and_path_order(self) -> None:
        self.record("z-old", sha=self.live, tree_hash=self.git("rev-parse", f"{self.live}^{{tree}}"))
        self.record("a-new", sha=self.candidate, tree_hash=self.git("rev-parse", "HEAD^{tree}"))
        self.record()
        self.assertEqual(self.resolve()["gate_scope_base"]["sha"], self.candidate)

    def test_no_record_requires_full_testing(self) -> None:
        self.assertFull(self.resolve())

    def test_failed_gate_cannot_supply_base(self) -> None:
        self.record(result="FAIL", exit_code=1)
        self.assertFull(self.resolve())

    def test_nonzero_exit_cannot_hide_behind_pass(self) -> None:
        self.record(exit_code=1)
        self.assertFull(self.resolve())

    def test_invalid_exit_types_rejected(self) -> None:
        for value in (False, "0", None):
            with self.subTest(value=value):
                self.record(exit_code=value)
                self.assertFull(self.resolve())

    def test_failure_for_same_commit_overrides_conflicting_success(self) -> None:
        self.record()
        self.record("failure", result="FAIL", exit_code=1)
        self.assertFull(self.resolve())

    def test_newer_failure_keeps_older_base_and_retests_failed_changes(self) -> None:
        self.record()
        self.record("failure", sha=self.candidate, result="FAIL", exit_code=1)
        self.assertEqual(self.resolve()["changed_paths"], ["fix.py"])

    def test_malformed_or_legacy_records_require_full_testing(self) -> None:
        for value in ("{broken", "[]", '{"gate":null}', '{"gate":{"result":"PASS"}}'):
            with self.subTest(value=value):
                self.write(".dt-build/bad/final-integration.json", value)
                self.assertFull(self.resolve())

    def test_incompatible_command_scope_and_contract_rejected(self) -> None:
        for fields in (dict(command="other"), dict(scope="unit-only"),
                       dict(contract_paths=["gate.py"]), dict(contract_paths=[])):
            with self.subTest(fields=fields):
                self.record(**fields)
                self.assertFull(self.resolve())

    def test_tree_mismatch_rejected(self) -> None:
        self.record(tree_hash=self.git("rev-parse", "HEAD^{tree}"))
        self.assertFull(self.resolve())

    def test_uncommitted_snapshot_rejected(self) -> None:
        self.record(clean=False)
        self.assertFull(self.resolve())

    def test_missing_clean_attestation_rejected(self) -> None:
        path = self.record()
        record = json.loads(path.read_text())
        del record["gate"]["clean"]
        path.write_text(json.dumps(record))
        self.assertFull(self.resolve())

    def test_movable_ref_rejected(self) -> None:
        self.record(sha="main")
        self.assertFull(self.resolve())

    def test_sibling_and_future_commits_rejected(self) -> None:
        self.git("checkout", "-qb", "sibling", self.live)
        self.write("sibling.py", "sibling")
        sibling = self.commit("sibling")
        tree = self.git("rev-parse", "HEAD^{tree}")
        self.git("checkout", "-q", "main")
        self.record(sha=sibling, tree_hash=tree)
        self.assertFull(self.resolve())
        self.record(sha=self.candidate, tree_hash=self.git("rev-parse", "HEAD^{tree}"))
        self.git("checkout", "-q", "--detach", self.gated)
        self.assertFull(self.resolve())

    def test_staged_unstaged_untracked_deleted_and_rename_included(self) -> None:
        self.record()
        self.write("checked.py", "working\n")
        self.write("staged.py", "staged\n")
        self.git("add", "staged.py")
        self.write("new\nfile.py", "untracked\n")
        self.git("mv", "old.py", "renamed.py")
        self.assertEqual(self.resolve()["changed_paths"],
                         ["checked.py", "fix.py", "new\nfile.py", "old.py", "renamed.py", "staged.py"])

    def test_changed_committed_contract_invalidates_record(self) -> None:
        self.record()
        self.write("suites.json", '{"changed":true}')
        self.commit("changed-suite-map")
        self.assertFull(self.resolve())

    def test_working_contract_changes_invalidate_record(self) -> None:
        self.record()
        self.write("gate.py", "new gate")
        self.assertFull(self.resolve())
        self.git("add", "gate.py")
        self.assertFull(self.resolve())

    def test_untracked_contract_directory_member_invalidates_record(self) -> None:
        self.record(contract_paths=[*CONTRACTS, "maps"])
        self.write("maps/new.json", "{}")
        result = MODULE.resolve_scope(self.repo, COMMAND, "release", [*CONTRACTS, "maps"])
        self.assertFull(result)

    def test_ship_config_command_mismatch_errors_instead_of_empty_diff(self) -> None:
        self.write(".ship.json", '{"gateCommand":"different"}')
        with self.assertRaisesRegex(ValueError, "differs"):
            self.resolve()

    def test_invalid_contract_paths_error(self) -> None:
        for value in ([], ["../gate.py"], ["/tmp/gate.py"], [":(glob)*"], ["literal:colon"], ["."]):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.resolve_scope(self.repo, COMMAND, "release", value)

    def test_failed_integration_cannot_supply_base(self) -> None:
        path = self.record()
        record = json.loads(path.read_text())
        record["result"] = "BLOCKED"
        path.write_text(json.dumps(record))
        self.assertFull(self.resolve())

    def test_explicit_external_record_and_nested_working_directory(self) -> None:
        path = self.record()
        external = self.repo / ".git" / "external.json"
        path.rename(external)
        nested = self.repo / "nested"
        nested.mkdir()
        result = MODULE.resolve_scope(nested, COMMAND, "release", CONTRACTS, [external])
        self.assertEqual(result["changed_paths"], ["fix.py"])

    def test_cli_is_read_only_and_returns_json(self) -> None:
        self.record()
        before = self.git("status", "--porcelain")
        proc = subprocess.run([sys.executable, str(SCRIPT), "--working-tree", str(self.repo),
                               "--command", COMMAND, "--scope", "release",
                               "--contract-path", "gate.py", "--contract-path", "suites.json"],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["changed_paths"], ["fix.py"])
        self.assertEqual(self.git("status", "--porcelain"), before)

    def produce(self, command: str = COMMAND, output: Path | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(PRODUCER), "--working-tree", str(self.repo),
             "--command", command, "--scope", "release", "--contract-path", "gate.py",
             "--contract-path", "suites.json", "--output", str(output or self.output)],
            capture_output=True, text=True)

    @property
    def output(self) -> Path:
        return self.repo / ".dt-build" / "actual" / "final-integration.json"

    def test_producer_runs_gate_under_ram_scratch_when_configured(self) -> None:
        tool = Path("/home/danny/Claude/_system-tools/ram-scratch/ram-scratch")
        if os.name == "nt" or not tool.exists():
            self.skipTest("ram-scratch helper not installed")
        self.write(".ship.json", json.dumps({"gateCommand": COMMAND, "scratch": {"mode": "auto", "capGb": 1}}))
        self.write("gate.py", "import os\nfrom pathlib import Path\n"
                   "Path('.dt-build/scratch.txt').write_text(os.environ.get('RAM_SCRATCH_MODE', '') + ' ' + os.environ['TMPDIR'])\n")
        self.commit("scratch-gate")
        scratch_root = Path(self.temp.name + " scratch")
        env = dict(os.environ, RAM_SCRATCH_RAM_ROOT=str(scratch_root / "shm"),
                   RAM_SCRATCH_DISK_ROOT=str(scratch_root / "disk"), RAM_SCRATCH_STATE=str(scratch_root / "state"),
                   RAM_SCRATCH_SAMPLE_S="0")
        self.addCleanup(shutil.rmtree, scratch_root, True)
        (self.repo / ".dt-build").mkdir(exist_ok=True)
        completed = subprocess.run(
            [sys.executable, str(PRODUCER), "--working-tree", str(self.repo), "--command", COMMAND,
             "--scope", "release", "--contract-path", "gate.py", "--contract-path", "suites.json",
             "--output", str(self.output)], capture_output=True, text=True, env=env)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        mode, tmp = (self.repo / ".dt-build" / "scratch.txt").read_text().split(" ", 1)
        self.assertIn(mode, ("ram", "disk"))
        self.assertTrue(tmp.startswith(str(scratch_root)))
        gate = json.loads(self.output.read_text())["gate"]
        self.assertEqual(gate["scratch"], {"mode": "auto", "cap_gb": 1})
        self.assertEqual(gate["result"], "PASS")

    def test_producer_to_resolver_next_commit_selects_only_subsequent_diff(self) -> None:
        # The actual gate consumes the producer's resolver output via its documented
        # environment input while the configured command remains byte-identical.
        self.write("gate.py", "import os\nfrom pathlib import Path\n"
                   "Path('.dt-build/executed.json').write_text(os.environ['DT_BUILD_GATE_SCOPE_JSON'])\n")
        gated = self.commit("executable-gate")
        self.output.parent.mkdir(parents=True)
        other = dict(result="PASS", verifier={"provenance": "kept"}, notes=["retained"], branch="main")
        self.output.write_text(json.dumps(other))
        completed = self.produce()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        record = json.loads(self.output.read_text())
        for key, value in other.items():
            self.assertEqual(record[key], value)
        gate = record["gate"]
        self.assertEqual(gate["command"], COMMAND)
        self.assertEqual(gate["before"], gate["after"])
        self.assertEqual(gate["sha"], gated)
        self.assertEqual(gate["contract_snapshot"], MODULE.dependency_snapshot(
            self.repo, gated, MODULE.contract_paths(CONTRACTS)))
        self.assertTrue(json.loads((self.repo / ".dt-build/executed.json").read_text())["full_test"])
        self.write("subsequent.py", "new fix\n")
        self.commit("next-commit")
        result = self.resolve()
        self.assertFalse(result["full_test"], result)
        self.assertEqual(result["gate_scope_base"]["sha"], gated)
        self.assertEqual(result["changed_paths"], ["subsequent.py"])

    def test_produced_current_head_empty_delta_requires_full_final_checks(self) -> None:
        completed = self.produce()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = self.resolve()
        self.assertTrue(result["already_gated"])
        self.assertTrue(result["full_test"])
        self.assertEqual(result["changed_paths"], [])
        self.assertEqual(result["gate_scope_base"]["reason"], "current-head-evidence-requires-validation")

    def test_failed_gate_replaces_old_pass_and_keeps_other_fields(self) -> None:
        self.write("gate.py", "import os\nraise SystemExit(7 if os.getenv('FIXTURE_GATE_FAIL') else 0)\n")
        self.commit("conditional-failure-gate")
        self.assertEqual(self.produce().returncode, 0)
        record = json.loads(self.output.read_text())
        record["verifier"] = {"keep": True}
        self.output.write_text(json.dumps(record))
        from unittest.mock import patch
        with patch.dict("os.environ", {"FIXTURE_GATE_FAIL": "1"}):
            completed = self.produce()
        self.assertNotEqual(completed.returncode, 0)
        record = json.loads(self.output.read_text())
        self.assertEqual(record["gate"]["exit_code"], 7)
        self.assertEqual(record["gate"]["result"], "FAIL")
        self.assertEqual(record["verifier"], {"keep": True})
        self.assertFull(self.resolve())

    def test_dirty_execution_cannot_produce_pass(self) -> None:
        self.write("gate.py", "from pathlib import Path\nPath('fix.py').write_text('dirty')\n")
        self.commit("dirtying-gate")
        self.assertNotEqual(self.produce().returncode, 0)
        gate = json.loads(self.output.read_text())["gate"]
        self.assertEqual(gate["before"]["status"], "")
        self.assertIn("fix.py", gate["after"]["status"])
        self.assertFalse(gate["clean"])
        self.assertFull(self.resolve())

    def test_head_move_during_execution_cannot_produce_pass(self) -> None:
        self.write("gate.py", "import subprocess\nsubprocess.run(['git','commit','--allow-empty','-qm','moved'],check=True)\n")
        self.commit("moving-gate")
        self.assertNotEqual(self.produce().returncode, 0)
        gate = json.loads(self.output.read_text())["gate"]
        self.assertNotEqual(gate["before"]["sha"], gate["after"]["sha"])
        self.assertEqual(gate["after"]["status"], "")
        self.assertFalse(gate["clean"])
        self.assertFull(self.resolve())

    def test_producer_refuses_dirty_start_and_incompatible_command(self) -> None:
        self.assertNotEqual(self.produce(command="python3 wrong.py").returncode, 0)
        self.assertFalse(self.output.exists())
        self.write("fix.py", "uncommitted")
        self.assertNotEqual(self.produce().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_produced_evidence_rejects_changed_config_and_snapshot(self) -> None:
        self.assertEqual(self.produce().returncode, 0)
        record = json.loads(self.output.read_text())
        record["gate"]["contract_snapshot"]["gate.py"] = "guessed"
        self.output.write_text(json.dumps(record))
        self.assertFull(self.resolve())
        self.assertEqual(self.produce().returncode, 0)
        self.write("suites.json", '{"changed": true}')
        self.commit("new-config")
        self.assertFull(self.resolve())

    def test_unignored_evidence_is_refused_and_resolver_is_conservative(self) -> None:
        self.record()
        self.write(".gitignore", "")
        self.git("add", ".gitignore")
        self.git("commit", "-qm", "unignore-evidence")
        self.assertNotEqual(self.produce().returncode, 0)
        result = self.resolve()
        self.assertTrue(result["full_test"])
        self.assertIn(".dt-build/good/final-integration.json", result["changed_paths"])

    def test_producer_refuses_tracked_symlink_and_metadata_outputs(self) -> None:
        tracked = self.repo / "suites.json"
        before = tracked.read_bytes()
        for output in (tracked, self.repo / ".git" / "evidence.json"):
            with self.subTest(output=output):
                self.assertNotEqual(self.produce(output=output).returncode, 0)
        self.assertEqual(tracked.read_bytes(), before)
        self.output.parent.mkdir(parents=True)
        self.output.symlink_to(tracked)
        self.assertNotEqual(self.produce().returncode, 0)
        self.assertEqual(tracked.read_bytes(), before)

    def test_recursive_producer_is_refused_through_gate(self) -> None:
        self.write("gate.py", f"import subprocess,sys\nraise SystemExit(subprocess.run([sys.executable, {str(PRODUCER)!r}, "
                   f"'--working-tree','.', '--command',{COMMAND!r}, '--scope','release', "
                   "'--contract-path','gate.py','--output','.dt-build/nested/final-integration.json']).returncode)\n")
        self.commit("indirect-recursion")
        self.assertNotEqual(self.produce().returncode, 0)
        self.assertIn("Recursive", self.output.with_suffix(".gate.log").read_text())
        self.assertFull(self.resolve())

    def test_powershell_semantics_match_actual_ship_step(self) -> None:
        # Load only the real runner function via the PowerShell AST. Never run
        # ship.ps1's main body (merge/push/deploy), nor a duplicate of the runner.
        ship = PRODUCER.parents[2] / "dt-ship" / "scripts" / "ship.ps1"
        harness = self.repo / ".dt-build/ship-runner.ps1"
        harness.parent.mkdir(parents=True)
        harness.write_text('''param($ShipScript, $CommandFile, $WorkingDirectory, $ResultFile)
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ShipScript, [ref]$null, [ref]$null)
$runner = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ShipStep'
}, $true)
Invoke-Expression $runner.Extent.Text
function Get-Prop { param($Object, $Name) return $null }
$StepTimeouts = @{}
$StepLogDir = Join-Path $WorkingDirectory '.dt-build/ship-logs'
$state = @{ timings = @{} }
$result = Invoke-ShipStep -Step 'fixture' -Command ([IO.File]::ReadAllText($CommandFile)) -WorkingDirectory $WorkingDirectory
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultFile -Encoding utf8
''', encoding="utf-8")
        snippets = [
            ("$label = 'PowerShell 雪'; Write-Output ($label.ToUpper() + ':' + (6 * 7)); exit 0",
             0, "POWERSHELL 雪:42"),
            ("python3 -c 'import sys; sys.exit(7)'; if ($LASTEXITCODE -ne 7) { throw 'lost exit' }; "
             "Write-Output \"native:$LASTEXITCODE\"; exit $LASTEXITCODE", 7, "native:7"),
            ("Write-Output 'before-throw'; throw 'PowerShell fixture failure'", 1, "before-throw"),
            ("bash -c 'exit 9'; exit $LASTEXITCODE", 9, ""),
            # EncodedCommand's implicit nonzero-native behavior must match too.
            ("python3 -c 'import sys; sys.exit(7)'", 1, ""),
        ]
        for command, code, marker in snippets:
            with self.subTest(command=command):
                self.write(".ship.json", json.dumps({"gateCommand": command}))
                self.commit("powershell-snippet")
                command_file = self.repo / ".dt-build/command.txt"
                command_file.write_text(command, encoding="utf-8")
                result_file = self.repo / ".dt-build/ship-result.json"
                actual = subprocess.run(
                    ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(harness),
                     str(ship), str(command_file), str(self.repo), str(result_file)],
                    capture_output=True, text=True)
                self.assertEqual(actual.returncode, 0, actual.stderr)
                shipped = json.loads(result_file.read_text(encoding="utf-8-sig"))
                completed = self.produce(command=command)
                record = json.loads(self.output.read_text())
                gate = record["gate"]
                self.assertEqual(gate["command"], command)
                self.assertEqual(gate["exit_code"], shipped["ExitCode"])
                self.assertEqual(gate["exit_code"], code)
                self.assertEqual(gate["result"], "PASS" if code == 0 else "FAIL")
                self.assertEqual(completed.returncode, 0 if code == 0 else 1, completed.stderr)
                log = self.output.with_suffix(".gate.log").read_text()
                self.assertIn(marker, log)
                self.assertIn(marker, shipped["Output"])
                if "throw 'PowerShell fixture failure'" in command:
                    self.assertIn("PowerShell fixture failure", log)
                if code:
                    self.assertTrue(MODULE.resolve_scope(self.repo, command, "release", CONTRACTS)["full_test"])

    def fixture_app(self) -> Path:
        child = self.repo / ".dt-build/fixture-app"
        child.mkdir(parents=True)
        for args in (("init", "-q", "-b", "main"), ("config", "user.name", "Fixture"),
                     ("config", "user.email", "fixture@example.invalid")):
            subprocess.run(["git", "-C", str(child), *args], check=True, capture_output=True)
        (child / ".gitignore").write_text(".dt-build/\n")
        (child / ".ship.json").write_text(json.dumps({"gateCommand": COMMAND}))
        (child / "gate.py").write_text("print('nested fixture gate ran')\n")
        (child / "suites.json").write_text("{}")
        for args in (("add", "."), ("commit", "-qm", "fixture")):
            subprocess.run(["git", "-C", str(child), *args], check=True, capture_output=True)
        return child

    def test_nested_recorder_for_isolated_fixture_app_succeeds(self) -> None:
        child = self.fixture_app()
        def quote(value: object) -> str:
            return "'" + str(value).replace("'", "''") + "'"
        # A legitimate direct fixture invocation even names record-gate.py in the
        # configured command; substring checks must not reject it.
        command = (f"& {quote(sys.executable)} {quote(PRODUCER)} --working-tree {quote(child)} "
                   f"--command {quote(COMMAND)} --scope release --contract-path gate.py "
                   f"--contract-path suites.json --output {quote(child / '.dt-build/child/final-integration.json')}; "
                   "exit $LASTEXITCODE")
        self.write(".ship.json", json.dumps({"gateCommand": command}))
        self.commit("gate-with-isolated-fixture-app")
        completed = self.produce(command=command)
        self.assertEqual(completed.returncode, 0, completed.stderr + self.output.with_suffix(".gate.log").read_text())
        child_record = json.loads((child / ".dt-build/child/final-integration.json").read_text())
        self.assertEqual(child_record["gate"]["result"], "PASS")
        self.assertEqual(json.loads(self.output.read_text())["gate"]["result"], "PASS")
        self.assertTrue(MODULE.resolve_scope(child, COMMAND, "release", CONTRACTS)["already_gated"])

    def test_cross_app_cycle_and_output_collision_are_refused(self) -> None:
        child = self.fixture_app()
        for collision in (False, True):
            with self.subTest(output_collision=collision):
                target = self.repo
                output = self.repo / ".dt-build/cycle/final-integration.json"
                (child / "gate.py").write_text(
                    f"import subprocess,sys\nraise SystemExit(subprocess.run([sys.executable, {str(PRODUCER)!r}, "
                    f"'--working-tree',{str(target)!r}, '--command',{COMMAND!r}, '--scope','other-scope', "
                    f"'--contract-path','gate.py','--output',{str(output)!r}]).returncode)\n")
                if not collision:
                    subprocess.run(["git", "-C", str(child), "add", "."], check=True)
                    subprocess.run(["git", "-C", str(child), "commit", "-qm", "cycle"], check=True)
                child_output = self.output if collision else child / '.dt-build/cycle/final-integration.json'
                self.write("gate.py", f"import subprocess,sys\nraise SystemExit(subprocess.run([sys.executable, {str(PRODUCER)!r}, "
                           f"'--working-tree',{str(child)!r}, '--command',{COMMAND!r}, '--scope','release', "
                           f"'--contract-path','gate.py','--output',"
                           f"{str(child_output)!r}]).returncode)\n")
                self.commit("gate-with-cyclic-fixture-app" if not collision else "gate-with-output-collision")
                completed = self.produce()
                self.assertNotEqual(completed.returncode, 0)
                error_log = (self.output if collision else child_output).with_suffix(".gate.log").read_text()
                self.assertIn("Recursive", error_log)
                self.assertEqual(json.loads(self.output.read_text())["gate"]["result"], "FAIL")

    def test_explicit_roadmap_command_without_ship_json(self) -> None:
        self.git("rm", ".ship.json")
        self.commit("roadmap-only")
        self.assertEqual(self.produce().returncode, 0)
        self.write("subsequent.py", "fix")
        self.commit("later-fix")
        self.assertEqual(self.resolve()["changed_paths"], ["subsequent.py"])

    def test_producer_preserves_blocked_integration_decision(self) -> None:
        self.output.parent.mkdir(parents=True)
        self.output.write_text(json.dumps({"result": "BLOCKED", "notes": ["verifier pending"]}))
        self.assertEqual(self.produce().returncode, 0)
        record = json.loads(self.output.read_text())
        self.assertEqual(record["result"], "BLOCKED")
        self.assertEqual(record["notes"], ["verifier pending"])
        self.assertEqual(record["gate"]["result"], "PASS")
        self.assertFull(self.resolve())


if __name__ == "__main__":
    unittest.main()
