import importlib.util
import json
import os
from pathlib import Path

from conftest import blocked_calls


def test_guard_holds_lock_without_children():
    assert os.environ['FIXTURE_NO_CHILDREN'] == '1'
    helper = Path(os.environ['FIXTURE_LOCK_HELPER'])
    spec = importlib.util.spec_from_file_location('no_children_probe', helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    holder = json.loads(module.STATUS.read_text())
    assert holder['state'] == 'held' and holder['admitted'] is True
    assert holder['token'] == os.environ['DANNY_PYTEST_OWNER']
    with module.LOCK.open('a+b') as handle:
        try:
            module.acquire(handle)
        except OSError:
            pass
        else:
            raise AssertionError('guard did not hold or reuse the machine lock')
    assert not blocked_calls
