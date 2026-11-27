#!/usr/bin/env python3
"""Best-effort CT202 SessionStart refresh; never stash, rebase, commit or push."""

import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

CANONICAL = Path('/home/danny/Claude/_Claude-Workspace/Skill Creation/danny-skills')
REMOTE = 'https://github.com/dtcmanage/danny-skills.git'
OPERATIONS = ('index.lock', 'HEAD.lock', 'packed-refs.lock', 'MERGE_HEAD',
              'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'REBASE_HEAD', 'BISECT_LOG',
              'rebase-merge', 'rebase-apply', 'sequencer')


def refresh(repo: Path, expected_remote: str = REMOTE, budget: float = 30) -> str:
    """Refresh one approved checkout. Alternate paths/URLs are for imported fixtures only.

    The deadline covers all subprocesses together, leaving the existing workspace
    transaction its 120 seconds within the SessionStart hook's 180-second budget.
    """
    deadline = time.monotonic() + budget
    env = os.environ.copy()
    env.update(GIT_TERMINAL_PROMPT='0', GCM_INTERACTIVE='Never',
               GIT_ASKPASS='/bin/false', SSH_ASKPASS='/bin/false',
               GIT_SSH_COMMAND='ssh -oBatchMode=yes -oStrictHostKeyChecking=yes')

    def git(*args: str) -> str:
        command = ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                   '-C', str(repo), *args]
        # Kill the whole child group on timeout/interruption, including credential helpers.
        with subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              start_new_session=True) as child:
            try:
                out, _ = child.communicate(timeout=max(.001, deadline - time.monotonic()))
            except BaseException:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
                raise
            if child.returncode:
                raise RuntimeError('git ' + args[0] + ' failed')
            return out.decode().strip()

    def safe() -> bool:
        if git('symbolic-ref', '--quiet', 'HEAD') != 'refs/heads/main':
            return False
        for name in OPERATIONS:
            path = Path(git('rev-parse', '--git-path', name))
            if (path if path.is_absolute() else repo / path).exists():
                return False
        return not git('status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none')

    try:
        repo = repo.resolve(strict=True)
        if Path(git('rev-parse', '--show-toplevel')).resolve() != repo:
            return 'skipped: checkout root mismatch'
        common = Path(git('rev-parse', '--git-common-dir'))
        if not common.is_absolute():
            common = repo / common
        # A dedicated crash-releasing lock serializes simultaneous SessionStart calls.
        with (common / 'skill-checkout-refresh.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 'skipped: refresh already running'
            if not safe():
                return 'skipped: tree is dirty, not main, or Git operation is active'
            for direction in ((), ('--push',)):
                if git('remote', 'get-url', *direction, '--all', 'origin').splitlines() != [expected_remote]:
                    return 'skipped: origin destination is not approved'
            before = git('rev-parse', 'HEAD')
            # Address the validated URL explicitly; never execute remote.origin.uploadpack.
            git('fetch', '--no-tags', '--no-recurse-submodules', expected_remote,
                'refs/heads/main:refs/remotes/origin/main')
            target = git('rev-parse', 'refs/remotes/origin/main')
            if not safe() or git('rev-parse', 'HEAD') != before:
                return 'skipped: checkout changed during fetch'
            if before == target:
                return 'current'
            # Reject local-ahead and divergent trees before merge can write ORIG_HEAD.
            git('merge-base', '--is-ancestor', before, target)
            git('-c', 'merge.autostash=false', 'merge', '--ff-only', '--no-edit', target)
            return 'updated: ' + before[:12] + ' -> ' + target[:12]
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        return 'skipped: ' + str(error).splitlines()[0]


def main() -> int:
    def stop(_signum: int, _frame: object) -> None:
        raise SystemExit(0)

    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, stop)
    if sys.platform != 'linux' or Path(__file__).resolve().parent.parent != CANONICAL:
        print('skill checkout refresh skipped: not the CT202 canonical checkout', file=sys.stderr)
        return 0
    print('skill checkout refresh ' + refresh(CANONICAL), file=sys.stderr)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
