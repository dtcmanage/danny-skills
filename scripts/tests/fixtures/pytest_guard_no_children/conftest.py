"""Install process denials before pytest_configure, as File Sorter does."""
import os
import subprocess
from unittest.mock import patch

blocked_calls = []
_patches = []


def _deny(*args, **kwargs):
    blocked_calls.append((args, kwargs))
    raise AssertionError('guard attempted to launch a child inside pytest')


# A pytest monkeypatch fixture would start too late: admission runs in configure.
if os.environ.get('FIXTURE_NO_CHILDREN') == '1':
    # Only the driver-created child enables denials. Merely discovering this
    # fixture directory in an unrelated repo-wide collection must stay inert.
    for module, names in (
        (subprocess, ('Popen', 'run', 'call', 'check_call', 'check_output')),
        (os, ('system', 'popen', 'fork', 'forkpty', 'posix_spawn', 'posix_spawnp',
              'spawnl', 'spawnle', 'spawnlp', 'spawnlpe', 'spawnv', 'spawnve',
              'spawnvp', 'spawnvpe')),
    ):
        for name in names:
            if hasattr(module, name):
                replacement = patch.object(module, name, _deny)
                replacement.start()
                _patches.append(replacement)


def pytest_unconfigure(config):
    # Keep denials installed through the guard's cleanup, including error paths.
    assert not blocked_calls, 'a child launch was attempted (even if caught)'
