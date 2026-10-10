"""Fake `codex app-server` for router tests: answers initialize and account/rateLimits/read.

FAKE_CODEX_LIMITS_PERCENT sets usedPercent (unset = reply with an error); every launch appends a
line to FAKE_CODEX_LIMITS_LOG so tests can count probes.
"""
import json, os, sys, time
log = os.environ.get('FAKE_CODEX_LIMITS_LOG')
if log:
    with open(log, 'a', encoding='utf-8') as handle:
        handle.write('launch\n')
percent = os.environ.get('FAKE_CODEX_LIMITS_PERCENT')
for line in sys.stdin:
    message = json.loads(line)
    if message.get('id') == 1:
        print(json.dumps({'id': 1, 'result': {'userAgent': 'fake'}}), flush=True)
    elif message.get('id') == 2:
        if percent is None:
            print(json.dumps({'id': 2, 'error': {'code': -1, 'message': 'not signed in'}}), flush=True)
        else:
            window = {'usedPercent': int(percent), 'windowDurationMins': 10080, 'resetsAt': int(time.time()) + 3 * 86400}
            print(json.dumps({'id': 2, 'result': {'rateLimits': {'limitId': 'codex', 'primary': window, 'secondary': None}}}), flush=True)
