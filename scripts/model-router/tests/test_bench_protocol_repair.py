"""Protocol regressions: synthetic payloads only; never launch a live CLI."""
from __future__ import annotations
import json
from pathlib import Path
import sys
import pytest
BENCH = Path(__file__).resolve().parents[1] / 'bench'
sys.path.insert(0, str(BENCH))
import codex_appserver as transport
import bench_engine as engine


@pytest.fixture(autouse=True)
def isolate_fixture_job_identity(monkeypatch):
    for name in ('DT_JOB_ID', 'DT_JOB_DIR', 'DT_BUILD_COORDINATOR_ID'):
        monkeypatch.delenv(name, raising=False)


def captured_host_declaration() -> dict:
    """codex-diag-7 names, keys and empty namespace description; synthetic tool values."""
    return {'type': 'additional_tools', 'id': 'host', 'role': 'developer', 'tools': [
        {'type': 'namespace', 'name': 'functions', 'description': '',
         'tools': [{'type': 'custom', 'name': 'exec', 'description': 'SYNTHETIC_EXEC',
                    'format': {'type': 'text'}},
                   {'type': 'function', 'name': 'wait', 'description': 'SYNTHETIC_WAIT',
                    'parameters': {'type': 'object'}, 'strict': False}]}]}


def observed_sequence(tmp_path: Path, variation: str = 'ok') -> dict:
    """Replay captured shapes with entirely synthetic field values."""
    declaration = captured_host_declaration()
    raw = {'type': 'message', 'id': 'final', 'role': 'assistant', 'phase': 'final_answer',
           'status': 'completed', 'internal_chat_message_metadata_passthrough': {'synthetic': True},
           'content': [{'type': 'output_text', 'text': 'synthetic answer', 'annotations': [], 'logprobs': []}]}
    if variation == 'extra_tool': declaration['tools'][0]['tools'].append({'type': 'function', 'name': 'other'})
    if variation == 'namespace': declaration['tools'][0]['name'] = 'other'
    if variation == 'extra_namespace': declaration['tools'].append(dict(declaration['tools'][0]))
    if variation == 'wrong_tool': declaration['tools'][0]['tools'][1]['name'] = 'other'
    if variation == 'wrong_type': declaration['tools'][0]['tools'][0]['type'] = 'function'
    if variation == 'namespace_description': declaration['tools'][0]['description'] = 'SYNTHETIC_DESCRIPTION'
    if variation == 'extra_exec_key': declaration['tools'][0]['tools'][0]['extra'] = True
    if variation == 'extra_wait_key': declaration['tools'][0]['tools'][1]['extra'] = True
    if variation == 'role': declaration['role'] = 'assistant'
    if variation == 'empty_id': declaration['id'] = ''
    if variation == 'status': raw['status'] = 'in_progress'
    if variation == 'logprobs': raw['content'][0]['logprobs'] = [0]
    if variation == 'annotations': raw['content'][0]['annotations'] = [0]
    if variation == 'null_logprobs': raw['content'][0]['logprobs'] = None
    if variation == 'unknown_raw': raw['type'] = 'SYNTHETIC_PRIVATE_TYPE'
    if variation == 'answer_mismatch': raw['content'][0]['text'] = 'different synthetic answer'
    usage = {'inputTokens': 10, 'cachedInputTokens': 0, 'cacheWriteInputTokens': 0,
             'outputTokens': 2, 'reasoningOutputTokens': 0, 'totalTokens': 12}
    base = {'threadId': 't', 'turnId': 'u'}
    events = []
    def add(method, **params): events.append({'method': method, 'params': params})
    def turn(method, **params): add(method, **base, **params)
    add('thread/started', thread={'id': 't', 'turns': []})
    warning = {'method': 'warning', 'params': {'threadId': 't', 'message': transport.DISABLED_HOST_WARNING}}
    if variation not in ('no_warning', 'late_warning'): events.append(warning)
    add('thread/status/changed', threadId='t', status={'type': 'active', 'activeFlags': []})
    turn('turn/started', turn={'id': 'u', 'items': [], 'status': 'inProgress', 'error': None})
    add('account/updated', authMode='chatgpt', planType='pro')
    turn('rawResponseItem/completed', item=declaration)
    if variation == 'second_declaration': turn('rawResponseItem/completed', item=declaration)
    if variation == 'late_warning': events.append(warning)
    for role, count in (('developer', 1), ('developer', 3), ('user', 1), ('user', 1)):
        turn('rawResponseItem/completed', item={'type': 'message', 'id': 'input', 'role': role,
             'content': [{'type': 'input_text', 'text': 'SYNTHETIC_INPUT'} for _ in range(count)],
             'internal_chat_message_metadata_passthrough': {'synthetic': True}})
    user = {'type': 'userMessage', 'id': 'user', 'content': [{'type': 'text', 'text': 'SYNTHETIC_INPUT', 'text_elements': []}],
            'clientId': None, 'startedAtMs': 1, 'completedAtMs': 2}
    turn('item/started', item=user)
    turn('item/completed', item=user, completedAtMs=2)
    turn('item/agentMessage/delta', itemId='final', delta='synthetic answer')
    turn('turn/moderationMetadata', metadata={'synthetic': 'SYNTHETIC_METADATA'})
    final = {'type': 'agentMessage', 'id': 'final', 'phase': 'final_answer', 'text': 'synthetic answer',
             'questions': [], 'memoryCitation': None, 'delivery': None, 'startedAtMs': 1, 'completedAtMs': 2}
    turn('item/completed', item=final, completedAtMs=2)
    turn('rawResponseItem/completed', item=raw)
    if variation != 'response_count':
        turn('rawResponse/completed', responseId='response', usage=usage, usageMetadata={'synthetic': True})
    turn('thread/tokenUsage/updated', tokenUsage={'total': usage})
    turn('turn/completed', turn={'id': 'u', 'items': [user, final], 'status': 'completed', 'error': None})
    source = Path(__file__).with_name('fake-appserver.py').read_text()
    replay = " if m=='turn/start':\n  for e in " + repr(events) + ":event(e['method'],e['params'])\n  emit({'id':rid,'result':{'turn':{'id':'u','items':[]}}});continue\n"
    # Events precede the RPC reply too, exercising the real receive/event buffer.
    source = source.replace(" if m=='turn/start':", replay + " if m=='turn/start':", 1)
    fake = tmp_path / 'observed.py'
    fake.write_text(source)
    return transport._run([sys.executable, str(fake), 'ok'],
        {'model': 'gpt-6.1-sol', 'effort': 'high', 'prompt': 'Synthetic fixture\nexact bytes'},
        tmp_path, 10000, dict(__import__('os').environ))


@pytest.mark.parametrize('variation', ['ok', 'late_warning'])
def test_observed_disabled_host_sequence_succeeds(tmp_path, variation):
    result = observed_sequence(tmp_path, variation)
    assert result['status'] == 'ok'
    assert result['tools'] == 'host disabled; unsupported attempts rejected'
    assert result['protocol_diagnostics']['rejected'] == []
    assert 'SYNTHETIC_' not in json.dumps(result)


@pytest.mark.parametrize('variation,reason', [
    *[(v, 'raw_item_invalid:additional_tools') for v in ('extra_tool', 'namespace', 'extra_namespace',
       'wrong_tool', 'wrong_type', 'namespace_description', 'extra_exec_key', 'extra_wait_key',
       'role', 'empty_id', 'no_warning', 'second_declaration')],
    *[(v, 'raw_item_invalid:message') for v in ('status', 'logprobs', 'annotations', 'null_logprobs')],
    ('unknown_raw', 'raw_item_invalid:OTHER'), ('response_count', 'response_count'),
    ('answer_mismatch', 'answer_mismatch'),
])
def test_observed_sequence_rejects_variations_with_fixed_reason(tmp_path, variation, reason):
    with pytest.raises(transport.BoundaryError, match='single-inference raw evidence missing or ambiguous') as error:
        observed_sequence(tmp_path, variation)
    assert error.value.protocol_diagnostics['reason'] == reason
    assert 'SYNTHETIC_' not in json.dumps(error.value.protocol_diagnostics)


@pytest.mark.parametrize('key', ['annotations', 'logprobs'])
@pytest.mark.parametrize('value', [None, {}, '', False, [0]])
def test_raw_output_metadata_only_accepts_empty_lists(key, value):
    assert not transport.valid_raw_content({'type': 'output_text', 'text': 'synthetic', key: value}, 'assistant', False)


def test_host_declaration_requires_verified_controls_and_warning():
    item = captured_host_declaration()
    assert not transport.valid_raw_item(item)
    assert not transport.valid_raw_item(item, controls_verified=True)
    assert not transport.valid_raw_item(item, disabled_host_warning=True)
    assert transport.valid_raw_item(item, controls_verified=True, disabled_host_warning=True)


@pytest.mark.parametrize('description', ['SYNTHETIC_DESCRIPTION', ' ', '\n', None, False])
def test_namespace_description_must_be_empty_string(description):
    item = captured_host_declaration()
    item['tools'][0]['description'] = description
    assert not transport.valid_raw_item(item, controls_verified=True, disabled_host_warning=True)


@pytest.mark.parametrize('index,key', [
    (index, key) for index, keys in enumerate((
        ('description', 'format', 'name', 'type'),
        ('description', 'name', 'parameters', 'strict', 'type')))
    for key in (*keys, 'extra')])
def test_nested_tool_key_sets_are_exact(index, key):
    item = captured_host_declaration()
    tool = item['tools'][0]['tools'][index]
    if key == 'extra':
        tool[key] = True
    else:
        del tool[key]
    assert not transport.valid_raw_item(item, controls_verified=True, disabled_host_warning=True)


@pytest.mark.parametrize('index,key,value', [
    (0, 'name', 'other'), (0, 'type', 'function'),
    (1, 'name', 'other'), (1, 'type', 'custom')])
def test_nested_tool_names_and_types_are_exact(index, key, value):
    item = captured_host_declaration()
    item['tools'][0]['tools'][index][key] = value
    assert not transport.valid_raw_item(item, controls_verified=True, disabled_host_warning=True)


@pytest.mark.parametrize('description', ['', 'Different synthetic tool description'])
def test_nested_tool_description_text_is_not_pinned(description):
    item = captured_host_declaration()
    for tool in item['tools'][0]['tools']:
        tool['description'] = description
    assert transport.valid_raw_item(item, controls_verified=True, disabled_host_warning=True)


@pytest.mark.parametrize('method', ['thread/prediction/updated', 'thread/readState/changed'])
def test_unapproved_thread_events_stay_rejected(tmp_path, method):
    with pytest.raises(transport.BoundaryError, match='unsupported event:'):
        peer(tmp_path, {'method': method, 'params': {'threadId': 't', 'turnId': 'u'}})


@pytest.mark.parametrize('method,params', [
    ('item/started', {'item': {'id': 'tool', 'type': 'customToolCall', 'name': 'exec'}}),
    ('rawResponseItem/completed', {'item': {'type': 'function_call', 'name': 'wait'}}),
])
def test_model_tool_attempt_stays_forbidden(tmp_path, method, params):
    with pytest.raises(transport.BoundaryError, match='tool or unsupported item forbidden'):
        peer(tmp_path, {'method': method, 'params': {'threadId': 't', 'turnId': 'u', **params}})


def peer(tmp_path: Path, event: dict) -> dict:
    source = Path(__file__).with_name('fake-appserver.py').read_text()
    source = source.replace("if scenario=='valid-lifecycle':", "if scenario=='repair':event(" + repr(event['method']) + "," + repr(event['params']) + ")\n  if scenario=='valid-lifecycle':")
    fake = tmp_path / 'peer.py'
    fake.write_text(source)
    return transport._run([sys.executable, str(fake), 'repair'],
        {'model':'gpt-6.1-sol','effort':'high','prompt':'Synthetic fixture\nexact bytes'},
        tmp_path, 5000, dict(__import__('os').environ))


def test_moderation_both_gates(tmp_path):
    result = peer(tmp_path, {'method':'turn/moderationMetadata', 'params':
        {'threadId':'t','turnId':'u','metadata':{'secret':'SYNTHETIC_RAW_METADATA'}}})
    assert result['status'] == 'ok'
    assert 'SYNTHETIC_RAW_METADATA' not in json.dumps(result)
    assert 'turn/moderationMetadata' in result['protocol_diagnostics']['seen']


@pytest.mark.parametrize('params', [
    {'threadId':'old','turnId':'u','metadata':None},
    {'threadId':'t','turnId':'old','metadata':None},
    {'threadId':'t','turnId':'u'},
    {'threadId':'t','turnId':2,'metadata':None},
])
def test_moderation_rejects_wrong_or_malformed_turn(tmp_path, params):
    with pytest.raises(transport.BoundaryError):
        peer(tmp_path, {'method':'turn/moderationMetadata','params':params})


def test_uncaptured_warning_has_bounded_diagnostic(tmp_path):
    with pytest.raises(transport.BoundaryError) as captured:
        peer(tmp_path, {'method':'warning','params':{'threadId':'t','message':'SYNTHETIC_WARNING_SECRET'}})
    assert str(captured.value) == 'unsupported event: warning'
    diagnostic = captured.value.protocol_diagnostics
    assert diagnostic['rejected'][0]['method'] == 'warning'
    assert 'SYNTHETIC_WARNING_SECRET' not in json.dumps(diagnostic)

@pytest.mark.parametrize('method,params', [
    ('item/started', {'threadId':'t','turnId':'u','item':{'type':'mcpToolCall','id':'x'}}),
    ('account/updated', {'authMode':'apikey'}),
    ('model/rerouted', {'threadId':'t','turnId':'u','fromModel':'gpt-6.1-sol','toModel':'gpt-6-luna'}),
    ('unknown/not-approved', {'threadId':'t','turnId':'u'}),
])
def test_boundary_restrictions_remain(tmp_path, method, params):
    with pytest.raises(transport.BoundaryError):
        peer(tmp_path, {'method':method,'params':params})


def test_server_requests_remain_forbidden():
    import queue, time
    server = object.__new__(transport.Server)
    server.deadline = time.monotonic()+3
    server.messages = queue.Queue()
    server.messages.put(json.dumps({'id':9,'method':'tool/request','params':{}}))
    with pytest.raises(transport.BoundaryError, match='server request forbidden'):
        server.receive()


def synthetic_run(tmp_path, monkeypatch, dispatch, *, parallel=32, alerts=None, grader='exact', config_extra=None):
    import shutil
    tasks = tmp_path / 'tasks'
    tasks.mkdir()
    monkeypatch.setattr(engine,'CANDIDATE_INPUTS',dict(engine.CANDIDATE_INPUTS))
    for index in range(16):
        name = f'normal-{index}'
        task = tasks / name
        task.mkdir()
        (task/'task.json').write_text(json.dumps({'id':name,'job':'fast','category':'mechanical','grader':grader}))
        (task/'prompt.md').write_text('Synthetic prompt')
        (task/'known-good.txt').write_text('OK')
        if grader == 'rubric':
            (task/'golden').mkdir()
            (task/'golden/rubric.json').write_text('{"criteria":{"clear":"Clear answer"}}')
            (task/'judge-prompt.md').write_text('Judge the synthetic answer.')
        engine.CANDIDATE_INPUTS[name] = ()
    config = json.loads((BENCH/'bench-config.json').read_text())
    config.update(max_parallel_calls=parallel,spend_stop_model_calls=10000)
    config.update(config_extra or {})
    return engine.run_bench(job='fast', candidate='gpt-6-luna',incumbent='claude-haiku-synthetic',
        effort='low',trigger='manual',state_dir=tmp_path/'state',tasks=tasks,config=config,
        dispatch=dispatch, limits=lambda v:{'blocked':False}, envelope=lambda a:a,
        outcome=lambda r:None,grade=lambda t,a:{'status':'pass'},structural_alert=alerts)


def test_32_lane_mixed_structural_halt_and_alerts(tmp_path, monkeypatch):
    import threading,time
    lock = threading.Lock()
    calls = []
    alerts = []
    def dispatch(request):
        if request['vendor']=='claude':
            return {'status':'ok','answer':'OK'}
        with lock:
            index = len(calls)
            calls.append(request)
        time.sleep(.02)
        return {'status':'unknown','failure_category':'protocol',
            'detail':'unsupported event: '+('warning' if index%2 else 'turn/moderationMetadata')}
    result = synthetic_run(tmp_path,monkeypatch,dispatch,alerts=alerts.append)
    assert result['halted'] is True and result['gate']=='unknown'
    assert 6 <= len(calls) <= 6+31
    assert all(row['attempt']==1 for row in result['outcomes'])
    assert set(alerts)=={'protocol:warning','protocol:turn/moderationMetadata'}
    assert len(alerts)==2 and result['quality_verdict']['verdict']=='unknown'
    assert not result['tie_qualified'] and not result['swap_qualified']
    from bench_ledger import read_ledger,summary_lines
    before = list(alerts)
    summary_lines(read_ledger(tmp_path/'state/bench'))
    assert alerts == before


def test_raw_evidence_failures_halt_without_retry(tmp_path, monkeypatch):
    alerts = []
    def dispatch(request):
        if request['vendor'] == 'claude':
            return {'status': 'ok', 'answer': 'OK'}
        return {'status': 'unknown', 'failure_category': 'protocol',
                'detail': 'single-inference raw evidence missing or ambiguous',
                'protocol_diagnostics': {'reason': 'raw_item_invalid:message'}}
    result = synthetic_run(tmp_path, monkeypatch, dispatch, alerts=alerts.append)
    assert result['halted'] and result['gate'] == 'unknown'
    assert all(row['attempt'] == 1 for row in result['outcomes'])
    assert alerts == ['protocol:turn/completed']
    assert not result['tie_qualified'] and not result['swap_qualified']


def test_timeout_retains_two_attempt_rule(tmp_path,monkeypatch):
    result = synthetic_run(tmp_path,monkeypatch,
        lambda request:{'status':'unknown','failure_category':'transport','detail':'Codex timeout'},parallel=6)
    assert not result.get('halted')
    groups = {}
    for row in result['outcomes']:
        groups.setdefault((row['side'],row['task_id'],row['rep']),[]).append(row['attempt'])
    assert groups and all(attempts==[1,2] for attempts in groups.values())


@pytest.mark.parametrize('detail', [
    'Codex transport failed', 'Codex stdin message limit', 'Empty dispatch response',
    'Conversion from JSON failed', 'Codex CLI missing', 'Parallel call returned nothing.',
    'single-inference raw evidence missing or ambiguous\n',
    'codex error: serverOverloaded', 'codex error: responseStreamDisconnected http 502'])
def test_outer_layer_failures_use_same_stop_rule(tmp_path, monkeypatch, detail):
    def dispatch(request):
        if request['vendor'] == 'claude':
            return {'status': 'ok', 'answer': 'OK'}
        raise RuntimeError(detail)
    result = synthetic_run(tmp_path, monkeypatch, dispatch, parallel=1)
    assert result['halted'] and result['gate'] == 'unknown'
    assert len([c for c in result['calls'] if c['vendor'] == 'codex']) == 6
    assert all(r['attempt'] == 1 for r in result['outcomes'])
    if detail.endswith('\n'):
        assert result['spend']['structural_failures'] == {'protocol:turn/completed': 6}


@pytest.mark.parametrize('event', [
    {'method': 'thread/settings/updated', 'params': {'threadId': 't'}},
    {'method': 'thread/settings/updated', 'params': {'threadId': 't', 'threadSettings': {}}},
    {'method': 'model/rerouted', 'params': {'threadId': 't', 'turnId': 'u'}},
])
def test_missing_identity_is_structural(tmp_path, monkeypatch, event):
    fixture = tmp_path / 'peer'; fixture.mkdir()
    with pytest.raises(transport.BoundaryError) as caught:
        peer(fixture, event)
    response = transport.classify_failure({'status': 'unknown', 'detail': str(caught.value)})
    assert response['failure_category'] == 'protocol'
    result = synthetic_run(tmp_path, monkeypatch, lambda r: response, parallel=1)
    assert result['halted'] and len([c for c in result['calls'] if c['vendor'] == 'codex']) == 6
    assert all(r['attempt'] == 1 for r in result['outcomes'])


@pytest.mark.parametrize('field', ['model', 'reasoningEffort', 'modelProvider'])
@pytest.mark.parametrize('value', [None, '', [], 3])
def test_start_identity_missing_or_malformed_halts(tmp_path, monkeypatch, field, value):
    original = transport.Server.request
    def request(server, method, params):
        reply = original(server, method, params)
        if method == 'thread/start':
            if value is None:
                reply.pop(field)
            else:
                reply[field] = value
        return reply
    monkeypatch.setattr(transport.Server, 'request', request)
    fixture = tmp_path / 'peer'; fixture.mkdir()
    with pytest.raises(transport.BoundaryError, match='malformed thread identity') as caught:
        peer(fixture, {'method': 'turn/moderationMetadata', 'params': {'threadId': 't', 'turnId': 'u', 'metadata': None}})
    response = transport.classify_failure({'status': 'unknown', 'detail': str(caught.value)})
    result = synthetic_run(tmp_path, monkeypatch, lambda r: response, parallel=1)
    assert result['halted'] and len([c for c in result['calls'] if c['vendor'] == 'codex']) == 6
    assert all(r['attempt'] == 1 for r in result['outcomes'])


@pytest.mark.parametrize('detail,signature', [
    ('account authentication changed or malformed', 'auth:account'),
    ('codex error: unauthorized http 401', 'auth:unauthorized')])
def test_auth_is_actionable_and_structural(tmp_path, monkeypatch, detail, signature):
    response = transport.classify_failure({'status': 'unknown', 'detail': detail})
    assert response['failure_category'] == 'auth'
    assert 're-authenticate' in response['detail']
    assert transport.structural_signature(response) == signature
    assert transport.classify_failure(response) == response
    result = synthetic_run(tmp_path, monkeypatch, lambda r: response, parallel=1)
    assert result['halted'] and len([c for c in result['calls'] if c['vendor'] == 'codex']) == 6
    assert all(r['attempt'] == 1 for r in result['outcomes'])


@pytest.mark.parametrize('surface', ['turn/completed', 'rpc'])
@pytest.mark.parametrize('info', ['unauthorized', {'unauthorized': {'httpStatusCode': 401}}])
def test_auth_error_surfaces_halt_without_retry(tmp_path, monkeypatch, surface, info):
    error = {'message': 'SYNTHETIC_PRIVATE_AUTH', 'codexErrorInfo': info}
    with pytest.raises(transport.BoundaryError) as captured:
        if surface == 'turn/completed':
            peer(tmp_path, {'method': surface, 'params': {'threadId': 't', 'turnId': 'u',
                'turn': {'id': 'u', 'items': [], 'status': 'failed', 'error': error}}})
        else:
            source = Path(__file__).with_name('fake-appserver.py').read_text()
            source = source.replace(" if m=='thread/start':", " if m=='thread/start':\n  emit({'id':rid,'error':" + repr(error) + "});continue\n if m=='thread/start':", 1)
            fake = tmp_path / 'rpc-auth.py'
            fake.write_text(source)
            transport._run([sys.executable, str(fake), 'ok'],
                {'model': 'gpt-6.1-sol', 'effort': 'high', 'prompt': 'Synthetic fixture\nexact bytes'},
                tmp_path, 10000, dict(__import__('os').environ))
    response = transport.classify_failure({'status': 'unknown', 'detail': str(captured.value)})
    assert response['failure_category'] == 'auth'
    assert transport.structural_signature(response) == 'auth:unauthorized'
    assert 're-authenticate' in response['detail']
    assert 'SYNTHETIC_PRIVATE_AUTH' not in json.dumps(response)
    result = synthetic_run(tmp_path, monkeypatch, lambda r: response, parallel=1)
    assert result['halted'] and result['gate'] == 'unknown'
    assert len([c for c in result['calls'] if c['vendor'] == 'codex']) == 6
    assert all(r['attempt'] == 1 for r in result['outcomes'])


@pytest.mark.parametrize('detail', ['codex error: unauthorized http 401',
    'account authentication changed or malformed', 'Codex timeout',
    'actual model or effort mismatch', 'ERROR: Usage limit reached',
    'unsupported event: warning', 'new synthetic boundary'])
def test_smoke_categories_match_shared_classifier(tmp_path, monkeypatch, detail):
    import subprocess
    response = transport.classify_failure({'status': 'unknown', 'detail': detail})
    entry = fake_smoke(tmp_path, monkeypatch, invalid=False)
    # Replace only the fixture copy's transport call; the report writer is real.
    payload = json.dumps(response).replace("'", "''")
    source = entry.read_text().replace('Invoke-BenchCli -Request $request -TimeoutMs 120000',
        "('" + payload + "' | ConvertFrom-Json -AsHashtable)")
    entry.write_text(source)
    completed = subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', str(entry),
        '-Vendor', 'codex', '-Model', 'gpt-6.1-sol', '-OutDir', str(tmp_path / 'out')],
        capture_output=True, text=True, timeout=60)
    report = json.loads((tmp_path / 'out/smoke-transport.json').read_text())
    assert completed.returncode == 1 and report['status'] == 'unknown'
    assert report['failure_category'] == response['failure_category']
    assert ('re-authenticate' in report['detail']) == (response['failure_category'] == 'auth')
    assert detail not in json.dumps(report)


def test_one_sided_ranked_quality_is_unknown(tmp_path):
    task=tmp_path/'ranked'
    task.mkdir()
    (task/'task.json').write_text('{"grader":"ranked"}')
    (task/'prompt.md').write_text('Synthetic brief')
    (task/'criteria.md').write_text('Synthetic criteria')
    result=engine.rank_tasks([task],run=tmp_path,job='coder',tier='standard',
        configurations={'candidate':{'model':'a','effort':'low'},'incumbent':{'model':'b','effort':'low'}},
        judges={'claude':'j1','codex':'j2'},judge_effort='high',
        call=lambda model,*args,**kw: {'status':'ok','answer':'OK'} if model=='a' else {'status':'unknown'},
        renderer=lambda *a:None)
    assert result['verdict']=='unknown'
    assert not engine.quality_decided(result)


def test_historical_unscored_read_time_unknown(tmp_path):
    from bench_ledger import read_ledger
    bench=tmp_path/'bench'
    bench.mkdir()
    rows=[{'at_utc':'2026-10-22','quality_verdict':'no_difference', 'tied':True,
        'tasks':{'candidate':{'passed':0,'failed':0},'incumbent':{'passed':3,'failed':0}}} for _ in range(10)]
    path=bench/'ledger.jsonl'
    text=''.join(json.dumps(row)+'\n' for row in rows)
    path.write_text(text)
    assert all(r['quality_verdict']=='unknown' and not r['tied'] for r in read_ledger(bench))
    assert path.read_text()==text


def test_schema_comparison_records_new_method_without_model_call(tmp_path):
    fake=tmp_path/'schema.py'
    fake.write_text("import json,sys;from pathlib import Path;assert sys.argv[1:3]==['app-server','generate-json-schema'];p=Path(sys.argv[4]);(p/'ServerNotification.json').write_text(json.dumps({'oneOf':[{'properties':{'method':{'enum':['synthetic/newEvent']}}}]}))")
    result=transport.schema_comparison([sys.executable,str(fake)])
    assert result=={'installed_count':1,'new_methods':['synthetic/newEvent']}


@pytest.mark.parametrize('model_args', [[], ['-Model','gpt-6-luna']])
def test_smoke_requires_live_before_any_cli(tmp_path,model_args):
    import subprocess
    result=subprocess.run(['pwsh','-NoProfile','-File',str(BENCH/'smoke-transport.ps1'),
        '-Vendor','codex','-OutDir',str(tmp_path/'probe'),*model_args],
        capture_output=True,text=True,timeout=15)
    assert result.returncode != 0
    assert 'explicit -Live' in result.stderr
    assert not (tmp_path/'probe').exists()


@pytest.mark.parametrize('args', [[], ['-Vendor', 'codex'], ['-OutDir', 'unused']])
def test_smoke_missing_mandatory_argument_noninteractive_fails_fast(tmp_path, args):
    import subprocess
    result = subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-File',
        str(BENCH/'smoke-transport.ps1'), *args], capture_output=True, text=True, timeout=10)
    assert result.returncode != 0
    assert 'missing mandatory parameters' in result.stderr


def fake_smoke(tmp_path: Path, monkeypatch, *, invalid: bool) -> Path:
    """Disposable entry copy bypasses only the Live gate; every CLI is synthetic.

    No test supplies -Live. The real entry's refusal is tested separately above.
    """
    import os
    auth = tmp_path/'auth'
    auth.mkdir()
    (auth/'auth.json').write_text('{}')
    monkeypatch.setenv('CODEX_HOME', str(auth))
    monkeypatch.setenv('DT_MODEL_ROUTER_STATE', str(tmp_path/'state'))
    source = Path(__file__).with_name('fake-appserver.py').read_text()
    source = source.replace("'Synthetic fixture\\nexact bytes'", "'Reply with exactly OK. Use no tools.'")
    source = source.replace("=='high'", " in ('low','high')")
    source = source.replace("'reasoningEffort':'high'", "'reasoningEffort':p['config']['model_reasoning_effort']")
    if invalid:
        source = source.replace("  if scenario!='raw-missing':event", "  raw['status']='in_progress'\n  if scenario!='raw-missing':event")
    schema_prefix = ("import json,sys\nfrom pathlib import Path\n"
        "if sys.argv[1:3]==['app-server','generate-json-schema']:\n"
        " (Path(sys.argv[4])/'ServerNotification.json').write_text(json.dumps({'properties':{'method':{'enum':['warning']}}}))\n"
        " sys.exit(0)\n"
        "assert sys.argv[1]=='app-server'\n"
        "sys.argv=['fake','ok']+sys.argv[2:]\n")
    fake_cli = tmp_path/'cli.py'
    fake_cli.write_text(schema_prefix + source)
    shim = tmp_path/'codex.ps1'
    # Single-quote literal paths; no command substitution or persistent PATH change.
    shim.write_text("& '" + sys.executable.replace("'", "''") + "' '" + str(fake_cli).replace("'", "''") + "' @args\nexit $LASTEXITCODE\n")
    monkeypatch.setenv('PATH', str(tmp_path) + os.pathsep + os.environ['PATH'])
    smoke = (BENCH/'smoke-transport.ps1').read_text()
    smoke = smoke.replace("if(-not $Live){throw 'A real model call requires explicit -Live.'}",
        "# Fixture copy: fake CLIs only; no Live switch.")
    # Anchor all imports/assets to production, but never use the real roster/state.
    smoke = smoke.replace('$PSScriptRoot', "'" + str(BENCH).replace("'", "''") + "'")
    smoke = smoke.replace("if(-not $Model){", "function Read-RouterRoster { @{roster=@{jobs=@{fast=@{first='claude-synthetic';backup='gpt-6.1-sol';backup_effort='low'}}}} }\nif(-not $Model){", 1)
    entry = tmp_path/'smoke-fixture.ps1'
    entry.write_text(smoke)
    return entry


@pytest.mark.parametrize('invalid', [False, True])
@pytest.mark.parametrize('explicit', [False, True])
def test_smoke_fake_cli_report_and_exit(tmp_path, monkeypatch, invalid, explicit):
    import subprocess
    entry = fake_smoke(tmp_path, monkeypatch, invalid=invalid)
    args = ['-Model', 'gpt-6.1-sol', '-Effort', 'high'] if explicit else []
    result = subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', str(entry),
        '-Vendor', 'codex', '-OutDir', str(tmp_path/'out'), *args], capture_output=True, text=True, timeout=30)
    report_path = tmp_path/'out/smoke-transport.json'
    assert report_path.exists(), result.stderr[-1000:]
    report = json.loads(report_path.read_text())
    assert result.returncode == (1 if invalid else 0)
    assert report['status'] == ('unknown' if invalid else 'ok')
    assert report['effort'] == ('high' if explicit else 'low')
    assert report['model'] == 'gpt-6.1-sol'
    records = {event['method']: event['observation'] for event in report['events']}
    for method in ('rawResponseItem/completed', 'rawResponse/completed'):
        assert records[method] == 'seen'
    assert 'UNKNOWN_SCHEMA_METHOD' not in report['diagnostics']['seen']
    if invalid:
        assert report['failure_category'] == 'protocol'
        assert report['detail'] == 'single-inference raw evidence missing or ambiguous'
        assert report['reason'] == report['diagnostics']['reason'] == 'raw_item_invalid:message'
    assert 'SYNTHETIC_' not in report_path.read_text()
    assert 'synthetic answer' not in report_path.read_text()


def test_job_explicit_exit_preserves_failed_smoke(tmp_path, monkeypatch):
    import subprocess
    entry = fake_smoke(tmp_path, monkeypatch, invalid=True)
    runner = BENCH.parents[2]/'skills/dt-build/scripts/dt-job-runner.ps1'
    generator = tmp_path/'wrapper.ps1'
    generator.write_text("""param($Runner,$Entry,$OutDir,$Generated)
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
$fn=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DtJobCommandScript'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$command="& pwsh -NoProfile -NonInteractive -File '$Entry' -Vendor codex -OutDir '$OutDir'; exit `$LASTEXITCODE"
[IO.File]::WriteAllText($Generated,(Get-DtJobCommandScript -Command $command))
""")
    generated = tmp_path/'generated.ps1'
    setup = subprocess.run(['pwsh','-NoProfile','-NonInteractive','-File',str(generator),
        str(runner),str(entry),str(tmp_path/'out'),str(generated)], capture_output=True,text=True,timeout=10)
    assert setup.returncode == 0, setup.stderr[-1000:]
    # Reproduce j-0013: the old generator reset the exit value just before exit.
    legacy = tmp_path/'legacy.ps1'
    legacy.write_text(generated.read_text().replace('; exit $LASTEXITCODE', '; $global:LASTEXITCODE = 0; exit $LASTEXITCODE'))
    before = subprocess.run(['pwsh','-NoProfile','-NonInteractive','-File',str(legacy)],
        capture_output=True,text=True,timeout=30)
    assert json.loads((tmp_path/'out/smoke-transport.json').read_text())['status'] == 'unknown'
    assert before.returncode == 0
    result = subprocess.run(['pwsh','-NoProfile','-NonInteractive','-File',str(generated)],
        capture_output=True,text=True,timeout=30)
    assert json.loads((tmp_path/'out/smoke-transport.json').read_text())['status'] == 'unknown'
    assert result.returncode == 1


def test_schema_is_saved_before_dispatch_entry(tmp_path,monkeypatch):
    import io
    fake=tmp_path/'schema.py'
    fake.write_text("import json,sys;from pathlib import Path;assert sys.argv[1:3]==['app-server','generate-json-schema'];(Path(sys.argv[4])/'ServerNotification.json').write_text(json.dumps({'properties':{'method':{'enum':['synthetic/newEvent']}}}))")
    arguments={'state_dir':str(tmp_path/'state'),'tasks':str(tmp_path/'tasks'),
        'schema_command':[sys.executable,str(fake)]}
    monkeypatch.setattr(sys,'stdin',io.StringIO(json.dumps(arguments)+'\n'))
    entered=[]
    def dispatch_entry(**kwargs):
        saved=json.loads((tmp_path/'state/bench/protocol-schema.json').read_text())
        assert saved['new_methods']==['synthetic/newEvent']
        assert kwargs['protocol_schema']==saved
        entered.append(True)
        return {'status':'fixture'}
    monkeypatch.setattr(engine,'run_bench',dispatch_entry)
    engine.main()
    assert entered==[True]


def test_completed_tier_survives_halt_without_proposal(tmp_path,monkeypatch):
    state=tmp_path/'state'
    report=state/'bench/runs/completed/report.json'
    report.parent.mkdir(parents=True)
    markdown=report.with_suffix('.md')
    markdown.write_text('Completed evidence')
    completed={'job':'coder','tier':'standard','gate':'pass','raw_gate':'pass',
        'tied':True,'tie_qualified':True,'swap_qualified':True,
        'report_paths':{'json':str(report),'markdown':str(markdown)},'outcomes':[{'status':'unknown'}]}
    report.write_text(json.dumps(completed))
    def first_then_halt(*,spend,guard,**arguments):
        spend.completed_reports.append(completed)
        for _ in range(6):
            spend.observe_dispatch('codex',{'status':'unknown','failure_category':'protocol','detail':'unsupported event: warning'})
        spend.before_call()
    monkeypatch.setattr(engine,'_run_bench',first_then_halt)
    alerts=[]
    result=engine.run_bench(job='coder',state_dir=state,config={},structural_alert=alerts.append)
    saved=json.loads(report.read_text())
    assert saved['outcomes']==[{'status':'unknown'}]
    assert saved['halted'] and saved['gate']=='unknown'
    assert not saved['tie_qualified'] and not saved['swap_qualified'] and not saved['tied']
    assert result['completed_tiers']==[saved]
    assert not (state/'tie-proposals').exists()
    assert alerts==['protocol:warning']


def test_shape_diagnostics_are_bounded_and_do_not_assume_usage():
    import queue,time
    server=object.__new__(transport.Server)
    server.deadline=time.monotonic()+3
    server.messages=queue.Queue()
    server.controls_verified=True
    server.protocol_diagnostics={'seen':[],'rejected':[]}
    for _ in range(12):
        server.messages.put(json.dumps({'method':'warning','params':{'message':'SECRET'*100,'unknown-secret-key':'SECRET'}}))
        with pytest.raises(transport.BoundaryError) as error:
            server.receive()
        assert error.value.usage is None and error.value.usage_partial
    diagnostics=server.protocol_diagnostics
    assert len(diagnostics['rejected'])==8
    assert 'SECRET' not in json.dumps(diagnostics)
    assert 'unknown-secret-key' not in json.dumps(diagnostics)


def test_successful_codex_completion_prevents_structural_threshold():
    spend=engine.ComparisonSpend(lambda:{},{})
    spend.observe_dispatch('codex',{'status':'ok','answer':'OK'})
    for index in range(12):
        spend.observe_dispatch('codex',{'status':'unknown','failure_category':'protocol',
            'detail':'unsupported event: '+('warning' if index%2 else 'turn/moderationMetadata')})
    assert spend.halted is None
    assert sum(spend.structural_failures.values())==12
    assert spend.codex_completions==1
    assert transport.structural_signature({'status':'unknown','failure_category':'protocol'}) == 'protocol:boundary'
    assert transport.structural_signature({'status':'unknown','failure_category':'identity','detail':'model mismatch'}) is None


def test_unknown_method_signatures_remain_distinct_without_raw_names():
    signatures=[]
    for name in ('SYNTHETIC_PRIVATE_METHOD_A','SYNTHETIC_PRIVATE_METHOD_B'):
        shape=transport.safe_event_shape({'method':name,'params':{'metadata':'SYNTHETIC_METADATA'}})
        assert name not in json.dumps(shape)
        signatures.append(transport.structural_signature({'status':'unknown','failure_category':'protocol',
            'detail':'unsupported event: UNKNOWN_SCHEMA_METHOD','protocol_diagnostics':{'rejected':[shape]}}))
    assert len(set(signatures))==2
    assert all(signature.startswith('protocol:UNKNOWN_SCHEMA_METHOD/') for signature in signatures)


@pytest.mark.parametrize('message', [
    'stale thread or turn event', 'tool or malformed turn payload forbidden',
    'malformed delta', 'unsupported thread status', 'required protocol ID missing'])
def test_each_protocol_rejection_halts_without_retry(tmp_path, monkeypatch, message):
    assert transport.failure_category(message) == 'protocol'
    result = synthetic_run(tmp_path, monkeypatch, lambda request: {
        'status': 'unknown', 'failure_category': transport.failure_category(message), 'detail': message}, parallel=6)
    assert result['halted'] and result['gate'] == 'unknown'
    codex_calls = [call for call in result['calls'] if call['vendor'] == 'codex']
    assert 6 <= len(codex_calls) <= 11
    codex_models = {call['model'] for call in codex_calls}
    codex_rows = [row for row in result['outcomes'] if row['model'] in codex_models]
    assert codex_rows and all(row['attempt'] == 1 for row in codex_rows)


@pytest.mark.parametrize('message', ['a future protocol rejection with PRIVATE text', ''])
def test_every_protocol_failure_has_a_safe_signature(message):
    # Use the production classifier, rather than supplying protocol ourselves.
    assert transport.failure_category(message) == 'protocol'
    assert transport.structural_signature({
        'status': 'unknown', 'failure_category': transport.failure_category(message), 'detail': message}) == 'protocol:boundary'


def test_all_literal_raise_sites_use_total_classification():
    import ast
    module = ast.parse(Path(transport.__file__).read_text())
    exceptions = {
        'Codex timeout': 'transport', 'stdin timeout': 'transport',
        'actual model or effort mismatch': 'identity',
        'model rerouted; comparison invalid': 'identity',
        'actual settings changed; comparison invalid': 'identity',
        'account authentication changed or malformed': 'auth',
        'native auth file unavailable for clean config': 'auth',
        'native auth reference unavailable for clean config': 'auth',
        'native auth reference verification failed': 'auth',
    }
    sites = [node.exc.args[0].value for node in ast.walk(module)
             if isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call)
             and isinstance(node.exc.func, ast.Name) and node.exc.func.id == 'BoundaryError'
             and node.exc.args and isinstance(node.exc.args[0], ast.Constant)
             and isinstance(node.exc.args[0].value, str)]
    assert len(sites) >= 50
    for message in sites:
        category = transport.failure_category(message)
        assert category == exceptions.get(message, 'protocol'), message
        signature = transport.structural_signature({'status': 'unknown', 'failure_category': category, 'detail': message})
        assert (signature is not None) == (category in ('protocol', 'auth')), message


@pytest.mark.parametrize('detail', [None, {'PRIVATE': True}])
def test_nontext_diagnostics_do_not_escape_signatures(detail):
    assert transport.structural_signature({'status': 'unknown', 'failure_category': 'protocol', 'detail': detail}) == 'protocol:boundary'
    assert transport.structural_signature({'status': 'unknown', 'failure_category': 'transport', 'detail': detail}) is None


@pytest.mark.parametrize('case,expected', [
    ('account', 'account authentication changed or malformed'),
    ('remote', 'remote control not disabled'),
    ('native-auth', 'native auth reference verification failed'),
    ('unexpected-python', 'app-server boundary failure'),
    ('future-rejection', 'brand new rejection nobody signed PRIVATE'),
    *[(field, 'malformed event payload') for field in ('turn', 'thread', 'tokenUsage', 'threadSettings')],
    ('thread-reply', 'malformed thread payload'), ('turn-reply', 'malformed turn payload'),
])
def test_real_boundary_failures_halt_at_six_calls(tmp_path, monkeypatch, case, expected):
    fixture = tmp_path / 'peer'
    fixture.mkdir()
    with monkeypatch.context() as patch:
        with pytest.raises(transport.BoundaryError) as captured:
            if case == 'native-auth':
                auth_home = fixture / 'auth'
                auth_home.mkdir()
                (auth_home / 'auth.json').write_text('{}')
                patch.setenv('CODEX_HOME', str(auth_home))
                patch.setattr(transport.os.path, 'samefile', lambda *args: False)
                with transport.native_config_home(fixture):
                    pytest.fail('Native auth verification must reject')
            else:
                method, params = 'turn/moderationMetadata', {'threadId': 't', 'turnId': 'u', 'metadata': None}
                if case == 'account':
                    method, params = 'account/updated', {'authMode': 'chatgpt', 'planType': 'PRIVATE_NEW_PLAN'}
                elif case == 'remote':
                    method, params = 'remoteControl/status/changed', {'status': 'connected'}
                elif case == 'unexpected-python':
                    def unexpected(*args):
                        raise TypeError('PRIVATE Python failure')
                    patch.setattr(transport, 'verify', unexpected)
                elif case == 'future-rejection':
                    def future_rejection(*args):
                        raise transport.BoundaryError('brand new rejection nobody signed PRIVATE')
                    patch.setattr(transport, 'verify', future_rejection)
                elif case.endswith('-reply'):
                    original = transport.Server.request
                    def malformed_reply(server, name, payload):
                        result = original(server, name, payload)
                        if name == ('thread/start' if case == 'thread-reply' else 'turn/start'):
                            result['thread' if case == 'thread-reply' else 'turn'] = 'PRIVATE malformed reply'
                        return result
                    patch.setattr(transport.Server, 'request', malformed_reply)
                else:
                    method = {'turn': 'turn/started', 'thread': 'thread/started',
                              'tokenUsage': 'thread/tokenUsage/updated', 'threadSettings': 'thread/settings/updated'}[case]
                    params = {'threadId': 't', 'turnId': 'u', case: 'PRIVATE malformed payload'}
                peer(fixture, {'method': method, 'params': params})
    assert str(captured.value) == expected
    response = {'status': 'unknown', 'failure_category': transport.failure_category(str(captured.value)),
                'detail': str(captured.value), 'protocol_diagnostics': captured.value.protocol_diagnostics}
    auth = case in ('account', 'native-auth')
    assert response['failure_category'] == ('auth' if auth else 'protocol')
    assert transport.structural_signature(response) == ('auth:account' if auth else 'protocol:boundary')
    # One lane measures the exact threshold; the separate 32-lane test covers
    # bounded in-flight overshoot. All six calls use the real site's classification.
    result = synthetic_run(tmp_path, monkeypatch,
        lambda request: response if request['vendor'] == 'codex' else {'status': 'ok', 'answer': 'OK'}, parallel=1)
    assert result['halted'] and result['gate'] == result['raw_gate'] == 'unknown'
    assert len([call for call in result['calls'] if call['vendor'] == 'codex']) == 6
    assert all(row['attempt'] == 1 for row in result['outcomes'])
    assert not result['tie_qualified'] and not result['swap_qualified']


def test_structural_codex_judge_failure_does_not_retry_rep(tmp_path, monkeypatch):
    def dispatch(request):
        if request['purpose'] == 'answer':
            return {'status': 'ok', 'answer': 'OK'}
        return {'status': 'unknown', 'failure_category': 'protocol' if request['vendor'] == 'codex' else 'transport',
                'detail': 'malformed delta' if request['vendor'] == 'codex' else 'timeout'}
    result = synthetic_run(tmp_path, monkeypatch, dispatch, grader='rubric', parallel=6)
    assert not result.get('halted')  # Successful Codex answers preclude the threshold stop.
    assert result['outcomes'] and all(row['attempt'] == 1 for row in result['outcomes'])
    assert all(row['status'] == 'unknown' and len(row['judge_scores']) == 2 for row in result['outcomes'])
    assert any(call['vendor'] == 'codex' and call['purpose'] == 'judge' for call in result['calls'])


@pytest.mark.parametrize('reason', ['weekly', 'call-cap'])
def test_spend_halt_preserves_completed_tier_gates(tmp_path, monkeypatch, reason):
    state = tmp_path / 'state'
    report = state / 'bench/runs/completed/report.json'
    report.parent.mkdir(parents=True)
    markdown = report.with_suffix('.md')
    markdown.write_text('Evidence')
    completed = {'job': 'coder', 'tier': 'standard', 'gate': 'pass', 'raw_gate': 'pass',
        'tied': True, 'better': None, 'quality_verdict': {'verdict': 'no_difference'},
        'report_paths': {'json': str(report), 'markdown': str(markdown)}}
    def halt(*, spend, **arguments):
        spend.completed_reports.append(completed)
        if reason == 'call-cap':
            spend.calls = spend.call_limit
            spend.before_call()
        else:
            spend.baselines['codex'] = {'used_percent': 0}
            spend.callback = lambda: {'codex': {'used_percent': 6}}
            spend.check()
    monkeypatch.setattr(engine, '_run_bench', halt)
    result = engine.run_bench(job='coder', state_dir=state, config={}, spend_check=lambda: {})
    saved = json.loads(report.read_text())
    assert result['halted'] and saved['halted']
    assert result['status'] == 'budget_halted'
    assert saved.get('status') != 'infrastructure_failure'
    assert result['quality_verdict'] is None
    assert saved['gate'] == saved['raw_gate'] == 'pass'
    assert saved['tied'] and saved['quality_verdict']['verdict'] == 'no_difference'
    assert not saved['tie_qualified'] and not saved['swap_qualified']


@pytest.mark.parametrize('reason', ['weekly', 'call-cap', 'structural'])
def test_final_spend_check_records_completed_calls_once(tmp_path, monkeypatch, reason):
    from bench_ledger import read_ledger
    state = tmp_path / 'state'
    run = state / 'bench/runs/completed'
    run.mkdir(parents=True)
    (run / 'report.md').write_text('Completed evidence')
    calls = [{'vendor': vendor, 'model': vendor + '-synthetic', 'status': 'ok', 'purpose': 'answer',
              'quota': {}, 'usage': {'input': 10, 'output': 1}} for vendor in ('claude', 'codex') for _ in range(48)]
    completed = {'job': 'coder', 'tier': 'standard', 'gate': 'pass', 'raw_gate': 'pass',
                 'tied': True, 'quality_verdict': {'verdict': 'no_difference'}, 'shadow': False,
                 'tie_qualified': False, 'swap_qualified': False,
                 'calls': calls, 'outcomes': [], 'configurations': {},
                 'report_paths': {'json': str(run / 'report.json'), 'markdown': str(run / 'report.md')}}
    def finish(*, spend, guard, **arguments):
        spend.completed_reports.append(completed)
        guard.current = completed
        spend.calls = len(calls)
        if reason == 'weekly':
            spend.baselines['codex'] = {'used_percent': 0}
            spend.callback = lambda: {'codex': {'used_percent': 6}}
        elif reason == 'call-cap':
            spend.call_limit = len(calls)
        else:
            for _ in range(6):
                spend.observe_dispatch('codex', {'status': 'unknown', 'failure_category': 'protocol'})
        return dict(completed, tiers=[completed])
    monkeypatch.setattr(engine, '_run_bench', finish)
    result = engine.run_bench(job='coder', state_dir=state, config={}, spend_check=lambda: {})
    rows = read_ledger(state / 'bench')
    assert len(rows) == 1
    assert rows[0]['claude']['calls'] == rows[0]['codex']['calls'] == 48
    if reason == 'call-cap':
        # The call cap guards the next call. Reaching it exactly after the last
        # tier has no next call to stop, unlike a final weekly or structural halt.
        assert not result.get('halted')
        return
    assert result['halted'] and not result['tie_qualified'] and not result['swap_qualified']
    if reason == 'structural':
        assert result['status'] == 'infrastructure_failure' and result['gate'] == 'unknown'
    else:
        assert result['status'] == 'budget_halted'
        assert result['gate'] == result['raw_gate'] == 'pass'
        assert result['quality_verdict']['verdict'] == 'no_difference'


def test_no_spend_callback_adds_no_call_cap(tmp_path, monkeypatch):
    result = synthetic_run(tmp_path, monkeypatch, lambda request: {'status': 'ok', 'answer': 'OK'},
        parallel=6, config_extra={'spend_stop_model_calls': 1})
    assert not result.get('halted') and result['spend']['model_calls'] > 1
    assert not result['spend']['fallback_call_cap']
    assert result['spend']['rules_in_force'] == []


@pytest.mark.parametrize('count', [0, 2, 3, None])
def test_historical_ranked_minimum_and_missing_data(tmp_path, count):
    from bench_ledger import read_ledger, summary_lines
    bench = tmp_path / 'bench'
    bench.mkdir()
    row = {'run_id': 'a' * 32, 'tier': 'standard', 'quality_verdict': 'no_difference', 'tied': True,
           'tasks': {side: {'passed': 3, 'failed': 0} for side in ('candidate', 'incumbent')}}
    ledger = bench / 'ledger.jsonl'
    ledger.write_text(json.dumps(row) + '\n')
    if count is not None:
        report = bench / 'runs' / row['run_id'] / 'report.json'
        report.parent.mkdir(parents=True)
        report.write_text(json.dumps({'tier': 'standard', 'quality_verdict': {'tasks': [{'reps': [
            {'judges': [{'reply': 'a'}, {'reply': 'a' if i < count else None}]} for i in range(6)]}]}}))
    before = {p: p.read_bytes() for p in bench.rglob('*') if p.is_file()}
    viewed = read_ledger(bench)[0]
    if count is not None and count < 3:
        assert viewed['quality_verdict'] == 'unknown' and not viewed['tied'] and viewed['better'] is None
        assert '| unknown |' in summary_lines([viewed])[-1]
    else:
        assert viewed['quality_verdict'] == 'no_difference' and viewed['tied']
    assert all(p.read_bytes() == content for p, content in before.items())
