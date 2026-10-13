"""Silent pytest admission guard. Loaded only through PYTEST_PLUGINS.

No tests, fixtures, markers or options. DANNY_PYTEST_GUARD=0 disables all work.
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path

import pytest

_ownership = None


@pytest.hookimpl(tryfirst=True)
def pytest_configure(config: pytest.Config) -> None:
    global _ownership
    if os.environ.get('DANNY_PYTEST_GUARD') == '0' or _ownership is not None:
        return
    # Installed copy has its stdlib helper alongside it. In-repo fixtures use
    # the authoritative helper in scripts/, without altering sys.path.
    helper = Path(__file__).resolve().with_name('pytest-lock.py')
    if not helper.is_file():
        helper = helper.parent.parent / 'pytest-lock.py'
    spec = importlib.util.spec_from_file_location('danny_pytest_guard_lock', helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    ownership = module.pytest_lock()
    try:
        ownership.__enter__()
    except (OSError, ValueError, RuntimeError) as error:
        raise pytest.UsageError(str(error)) from error
    _ownership = ownership


def _release() -> None:
    global _ownership
    ownership, _ownership = _ownership, None
    if ownership is not None:
        ownership.__exit__(None, None, None)


@pytest.hookimpl(trylast=True)
def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    _release()


def pytest_unconfigure(config: pytest.Config) -> None:
    # Also covers configure/collection errors and embedded pytest.main calls.
    _release()
