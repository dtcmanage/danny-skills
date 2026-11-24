"""Trust-writer regression contract. All configs and app-server replies are fixtures."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("trust_editor", SCRIPTS / "codex_hook_trust.py")
editor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(editor)
KEY = "/home/danny/.codex/hooks.json:pre_tool_use:0:0"
OLD = "sha256:" + "a" * 64
NEW = "sha256:" + "b" * 64


class TrustContract:
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="codex-hook-trust-test-")
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / "config.toml"

    def update(self, key: str = KEY, digest: str = NEW) -> None:
        editor.set_codex_trust(self.config, key, digest)

    def run_case(self, text: str, key: str = KEY) -> tuple[str, dict]:
        self.config.write_bytes(text.encode("utf-8"))
        self.update(key)
        result = self.config.read_bytes().decode("utf-8")
        doc = tomllib.loads(result)
        self.assertEqual(doc["hooks"]["state"][key]["trusted_hash"], NEW)
        self.update(key)
        self.assertEqual(self.config.read_bytes().decode("utf-8"), result, "second update is idempotent")
        return result, doc

    def test_double_quotes_updated_in_place(self) -> None:
        header = f'[hooks.state."{KEY}"]'
        out, doc = self.run_case(f'model = "test"\n{header}\ntrusted_hash = "{OLD}"\n[other]\nx = 1\n')
        self.assertEqual(out.count(header), 1)
        self.assertEqual(doc["other"], {"x": 1})
        self.assertEqual(doc["model"], "test")

    def test_all_equivalent_header_forms(self) -> None:
        for header in (f"[ hooks . state . '{KEY}' ] # comment", f'["hooks" . \'state\' . "{KEY}"]',
                       '[hooks.state."' + KEY.replace("/", "\\u002f") + '"]'):
            with self.subTest(header=header):
                out, _ = self.run_case(header + f'\n"trusted_hash" = "{OLD}"\n')
                self.assertIn(header, out)

    def test_duplicate_tables_collapsed_current_hash_wins(self) -> None:
        text = (f'[hooks.state."{KEY}"]\ntrusted_hash = "{OLD}"\nfirst = 1\n'
                f'[other]\nvalue = 42\n[ hooks . state . \'{KEY}\' ]\ntrusted_hash = "sha256:{"c" * 64}"\nlast = 2\n')
        out, doc = self.run_case(text)
        self.assertNotIn(f'[hooks.state."{KEY}"]', out)
        self.assertEqual(doc["hooks"]["state"][KEY], {"trusted_hash": NEW, "first": 1, "last": 2})
        self.assertEqual(doc["other"]["value"], 42)

    def test_new_key_appended_once(self) -> None:
        _, doc = self.run_case('[hooks.state.other]\ntrusted_hash = "preserved"\n')
        self.assertEqual(len(doc["hooks"]["state"]), 2)
        self.assertEqual(doc["hooks"]["state"]["other"]["trusted_hash"], "preserved")

    def test_empty_or_missing_config(self) -> None:
        self.update()
        self.assertEqual(tomllib.loads(self.config.read_text())["hooks"]["state"][KEY]["trusted_hash"], NEW)
        self.run_case("")

    def test_missing_hash_and_crlf(self) -> None:
        out, _ = self.run_case(f"[hooks.state.'{KEY}']\r\n# keep\r\n")
        self.assertNotIn("\n", out.replace("\r\n", ""))
        self.assertIn("# keep", out)

    def test_escaped_key(self) -> None:
        key = 'C:\\User\\a\'b".json:pre_tool_use:0:0'
        self.run_case('[hooks.state.' + json.dumps(key) + ']\n', key)

    def test_multiline_and_array_content_preserved(self) -> None:
        for quote in ('"""', "'''"):
            with self.subTest(quote=quote):
                text = (f'note = {quote}\n[hooks.state."{KEY}"]\ntrusted_hash = "fake"\n{quote}\n'
                        f'[hooks.state."{KEY}"]\nvalues = [\n "a",\n "b",\n]\n'
                        f'note = {quote}\ntrusted_hash = "fake"\n{quote}\ntrusted_hash = "{OLD}"\n')
                _, doc = self.run_case(text)
                self.assertIn('trusted_hash = "fake"', doc["note"])
                self.assertEqual(doc["hooks"]["state"][KEY]["values"], ["a", "b"])
                self.assertEqual(doc["hooks"]["state"][KEY]["note"], 'trusted_hash = "fake"\n')

    def test_invalid_result_refused_original_untouched(self) -> None:
        for text in ('invalid = [\n', f'[hooks.state."{KEY}"]\nother = 1\n'
                     f"[hooks.state.'{KEY}']\nother = 2\n", '[other]\nx = 1\nx = 2\n'):
            with self.subTest(text=text):
                original = text.encode()
                self.config.write_bytes(original)
                with self.assertRaises(Exception):
                    self.update()
                self.assertEqual(self.config.read_bytes(), original)
                self.assertEqual(list(self.config.parent.glob("*.tmp")), [])

    def test_invalid_hash_refused(self) -> None:
        self.config.write_text("# preserved\n")
        with self.assertRaises(Exception):
            self.update(digest='bad"\n')
        self.assertEqual(self.config.read_text(), "# preserved\n")


class PythonWriterTests(TrustContract, unittest.TestCase):
    def test_replace_failure_cleans_temp(self) -> None:
        self.config.write_text("# preserved\n")
        with patch.object(editor.os, "replace", side_effect=OSError("fixture failure")):
            with self.assertRaises(OSError):
                self.update()
        self.assertEqual(self.config.read_text(), "# preserved\n")
        self.assertEqual(list(self.config.parent.glob("*.tmp")), [])

    def test_exact_candidate_validated_before_replace(self) -> None:
        self.config.write_text("# preserved\n")
        with patch.object(editor, "updated_trust", return_value="bad = [\n"):
            with self.assertRaises(tomllib.TOMLDecodeError):
                self.update()
        self.assertEqual(self.config.read_text(), "# preserved\n")
        self.assertEqual(list(self.config.parent.glob("*.tmp")), [])


class PowerShellWriterTests(TrustContract, unittest.TestCase):
    def update(self, key: str = KEY, digest: str = NEW) -> None:
        fixture = self.config.parent / "hooks-list.json"
        fixture.write_text(json.dumps({"hooks": [{"key": key, "currentHash": digest,
                                                "source": "sessionFlags", "trustStatus": "untrusted"}]}))
        env = dict(os.environ, CODEX_HOME=str(self.config.parent), DT_BUILD_CODEX_HOOK_LIST_JSON=str(fixture))
        proc = subprocess.run(["pwsh", "-NoProfile", "-File", str(SCRIPTS / "ensure-codex-hook-trust.ps1"),
                               "-HookOverrides", "fixture"], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        if result["status"] != "ok":
            raise RuntimeError(result["error"])


if __name__ == "__main__":
    unittest.main()
