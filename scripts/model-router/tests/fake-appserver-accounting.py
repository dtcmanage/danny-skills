"""Offline test-only event mutations around the existing synthetic peer."""
import builtins, json, runpy, sys
from pathlib import Path
case = sys.argv[1]
sys.argv[1] = {'stale216':'usage-retry','cumulative162':'usage-cumulative','duplicate':'raw-duplicate'}.get(case, 'ok')
original = builtins.print
base = {'threadId':'t','turnId':'u'}
error = {'message':'Usage limit reached; resets at 2099-10-02T20:00:00Z api_key=SECRET_SENTINEL', 'additionalDetails':'CONFIG_SECRET_SENTINEL'}
def emit(value): original(json.dumps(value), flush=True)
def intercept(text, **kwargs):
    event = json.loads(text)
    method = event.get('method')
    if case.startswith('account:') and event.get('id') == 1 and event.get('result') == {}:
        variant = case.split(':')[1]
        params = {'authMode':'chatgpt','planType':'pro'}
        if variant == 'api': params['authMode'] = 'apikey'
        elif variant == 'missing': params.pop('authMode')
        elif variant == 'null': params['authMode'] = None
        elif variant == 'extra': params['token'] = 'SECRET_SENTINEL'
        elif variant == 'plan': params['planType'] = 'unexpected'
        emit({'method':'account/updated','params':params})
    if case == 'raw216' and method == 'thread/tokenUsage/updated': return
    if case == 'quota-turn' and method == 'turn/completed':
        event['params']['turn']['status'] = 'failed'
        event['params']['turn']['error'] = error
    emit(event)
    if method == 'rawResponse/completed':
        if case == 'raw216': emit({'method':method,'params':dict(event['params'],responseId='resp-2')})
        if case == 'invalid108': emit({'method':'thread/tokenUsage/updated','params':dict(base,tokenUsage={'total':None})})
        if case == 'quota-notification': emit({'method':'error','params':dict(base,error=error,willRetry=False)})
builtins.print = intercept
runpy.run_path(str(Path(__file__).with_name('fake-appserver.py')), run_name='__main__')
