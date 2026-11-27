"""Disposable real Git repositories only: no network or installed checkout writes."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

import pytest

# Skip during collection, before either fcntl or the CT202-only helper loads.
if sys.platform != 'linux':
    pytest.skip('CT202 Linux refresh', allow_module_level=True)
fcntl = pytest.importorskip('fcntl')

spec = importlib.util.spec_from_file_location('refresh_checkout', Path(__file__).parents[1] / 'refresh-checkout.py')
refresh_checkout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh_checkout)


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.PIPE).decode().strip()


@pytest.fixture
def checkout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> tuple[Path, Path, Path]:
    monkeypatch.setenv('GIT_CONFIG_GLOBAL', '/dev/null')
    monkeypatch.setenv('GIT_CONFIG_SYSTEM', '/dev/null')
    seed, remote, repo = (tmp_path / name for name in ('seed', 'remote.git', 'checkout'))
    seed.mkdir()
    git(seed, 'init', '-q', '-b', 'main')
    git(seed, 'config', 'user.name', 'Fixture')
    git(seed, 'config', 'user.email', 'fixture@example.invalid')
    (seed / 'tracked').write_text('base\n')
    git(seed, 'add', '.')
    git(seed, 'commit', '-qm', 'base')
    git(tmp_path, 'clone', '-q', '--bare', str(seed), str(remote))
    git(tmp_path, 'clone', '-q', str(remote), str(repo))
    git(repo, 'config', 'user.name', 'Fixture')
    git(repo, 'config', 'user.email', 'fixture@example.invalid')
    (seed / 'tracked').write_text('upstream\n')
    git(seed, 'commit', '-qam', 'upstream')
    git(seed, 'push', '-q', str(remote), 'main')
    return repo, remote, seed


def snapshot(repo: Path) -> tuple:
    root = Path(git(repo, 'rev-parse', '--absolute-git-dir'))
    return (git(repo, 'rev-parse', 'HEAD'), (root / 'HEAD').read_bytes(),
            git(repo, 'status', '--porcelain=v1', '--untracked-files=all'),
            {str(p.relative_to(repo)): p.read_bytes() for p in repo.rglob('*')
             if p.is_file() and root not in p.parents},
            (root / 'index').read_bytes(),
            {name: (root / name).read_bytes() for name in refresh_checkout.OPERATIONS
             if (root / name).is_file()})


def test_clean_main_updates(checkout: tuple) -> None:
    repo, remote, seed = checkout
    result = refresh_checkout.refresh(repo, str(remote))
    assert result.startswith('updated:'), result
    assert git(repo, 'rev-parse', 'HEAD') == git(seed, 'rev-parse', 'HEAD')
    assert (repo / 'tracked').read_text() == 'upstream\n'
    assert refresh_checkout.refresh(repo, str(remote)) == 'current'


@pytest.mark.parametrize('kind', ['unstaged', 'staged', 'untracked', 'non-main', 'detached', 'divergent', 'ahead'])
def test_preserves_unsafe_checkout(checkout: tuple, kind: str) -> None:
    repo, remote, _ = checkout
    if kind in ('staged', 'unstaged'):
        (repo / 'tracked').write_bytes(b'local\x00bytes\n')
        if kind == 'staged':
            git(repo, 'add', 'tracked')
    elif kind == 'untracked':
        (repo / 'new file').write_text('preserve me')
    elif kind == 'non-main':
        git(repo, 'checkout', '-qb', 'feat/work')
    elif kind == 'detached':
        git(repo, 'checkout', '-q', '--detach')
    else:
        if kind == 'ahead':
            git(repo, 'fetch', '-q', str(remote), 'main')
            git(repo, 'merge', '-q', '--ff-only', 'FETCH_HEAD')
        (repo / 'local').write_text('local commit')
        git(repo, 'add', '.')
        git(repo, 'commit', '-qm', 'local')
    before = snapshot(repo)
    result = refresh_checkout.refresh(repo, str(remote))
    assert result.startswith('skipped:'), result
    assert snapshot(repo) == before


@pytest.mark.parametrize('operation', refresh_checkout.OPERATIONS)
def test_preserves_active_operation(checkout: tuple, operation: str) -> None:
    repo, remote, _ = checkout
    path = Path(git(repo, 'rev-parse', '--absolute-git-dir')) / operation
    if operation in ('rebase-merge', 'rebase-apply', 'sequencer'):
        path.mkdir()
        (path / 'owned-state').write_text('do not abort or recover')
    else:
        path.write_text('in-progress state\n')
    before = snapshot(repo)
    result = refresh_checkout.refresh(repo, str(remote))
    assert result.startswith('skipped:'), result
    assert snapshot(repo) == before
    assert path.exists()
    if path.is_dir():
        assert (path / 'owned-state').read_text() == 'do not abort or recover'


def test_failed_fetch_preserves_tree(checkout: tuple) -> None:
    repo, remote, _ = checkout
    shutil.rmtree(remote)
    before = snapshot(repo)
    assert 'fetch failed' in refresh_checkout.refresh(repo, str(remote))
    assert snapshot(repo) == before


@pytest.mark.parametrize('change', ['pushurl', 'multiple', 'rewrite'])
def test_rejects_unapproved_destination(checkout: tuple, change: str) -> None:
    repo, remote, _ = checkout
    if change == 'pushurl':
        git(repo, 'config', 'remote.origin.pushurl', '/unapproved')
    elif change == 'multiple':
        git(repo, 'config', '--add', 'remote.origin.url', '/unapproved')
    else:
        git(repo, 'config', 'url./unapproved.insteadOf', str(remote))
    assert 'not approved' in refresh_checkout.refresh(repo, str(remote))
    assert (repo / 'tracked').read_text() == 'base\n'


def test_serializes_overlapping_refresh(checkout: tuple) -> None:
    repo, remote, _ = checkout
    with (repo / '.git/skill-checkout-refresh.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        assert 'already running' in refresh_checkout.refresh(repo, str(remote))
    assert refresh_checkout.refresh(repo, str(remote)).startswith('updated:')


def test_rechecks_dirty_tree_after_fetch(checkout: tuple, monkeypatch: pytest.MonkeyPatch) -> None:
    repo, remote, _ = checkout
    original = subprocess.Popen

    def start(command: list, **kwargs: object) -> subprocess.Popen:
        if 'fetch' in command:
            (repo / 'tracked').write_text('arrived during fetch\n')
        return original(command, **kwargs)

    monkeypatch.setattr(refresh_checkout.subprocess, 'Popen', start)
    before = git(repo, 'rev-parse', 'HEAD')
    assert 'changed during fetch' in refresh_checkout.refresh(repo, str(remote))
    assert git(repo, 'rev-parse', 'HEAD') == before
    assert (repo / 'tracked').read_text() == 'arrived during fetch\n'


def test_timeout_kills_fetch_children(checkout: tuple, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    repo, remote, _ = checkout
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    real_git = shutil.which('git')
    pid_file = tmp_path / 'child.pid'
    wrapper = bin_dir / 'git'
    wrapper.write_text('#!/bin/bash\nfor arg in "$@"; do\n'
                       'if [ "$arg" = fetch ]; then\n'
                       f'  sleep 60 &\n  echo $! > "{pid_file}"\n  wait\n  exit 1\nfi\ndone\n'
                       f'exec "{real_git}" "$@"\n')
    wrapper.chmod(0o755)
    before = snapshot(repo)
    monkeypatch.setenv('PATH', str(bin_dir) + ':' + os.environ['PATH'])
    started = time.monotonic()
    assert 'timed out' in refresh_checkout.refresh(repo, str(remote), budget=3)
    assert time.monotonic() - started < 6
    child = Path('/proc') / pid_file.read_text().strip() / 'stat'
    assert not child.exists() or child.read_text().split()[2] == 'Z'
    assert snapshot(repo) == before


def test_cli_refuses_feature_worktree() -> None:
    result = subprocess.run([sys.executable, str(Path(refresh_checkout.__file__))], capture_output=True, text=True)
    assert result.returncode == 0
    assert 'not the CT202 canonical checkout' in result.stderr
