"""Bench-owned Codex stdio transport. Never persist server config or diagnostics."""
from __future__ import annotations

import json
from contextlib import contextmanager
from datetime import datetime, timezone
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import threading
import time
import tempfile
from typing import Any

SOURCES = ('apps', 'plugins', 'browser_use', 'browser_use_external',
           'computer_use', 'multi_agent', 'multi_agent_v2', 'image_generation',
           'hooks', 'memories', 'skill_search', 'code_mode_host', 'sleep_tool',
           'current_time_reminder')
DISABLED_HOST_WARNING = ('Code Mode is unavailable because code-mode host is disabled. '
    'Code mode will fail closed; enable `features.code_mode_host` and install `codex-code-mode-host`.')
BENIGN = {'thread/started', 'thread/status/changed', 'turn/started',
          'thread/settings/updated', 'item/started', 'item/completed', 'item/agentMessage/delta',
          'item/reasoning/summaryTextDelta', 'item/reasoning/summaryPartAdded',
          'item/reasoning/textDelta', 'thread/tokenUsage/updated', 'turn/completed'}
BENIGN |= {'rawResponseItem/completed', 'rawResponse/completed', 'account/rateLimits/updated'}
BENIGN_ITEMS = {'userMessage', 'agentMessage', 'reasoning'}
BENCH_INSTRUCTIONS = Path(__file__).with_name('direct-answer-system-prompt.txt').read_text(encoding='utf-8').strip()

QUOTA_SCHEMA = {'$schema': 'http://json-schema.org/draft-07/schema#', 'definitions': {'CreditsSnapshot': {'properties': {'balance': {'type': ['string', 'null']}, 'hasCredits': {'type': 'boolean'}, 'unlimited': {'type': 'boolean'}}, 'required': ['hasCredits', 'unlimited'], 'type': 'object'}, 'PlanType': {'enum': ['free', 'go', 'plus', 'pro', 'prolite', 'promax', 'team', 'self_serve_business_prolite', 'self_serve_business_usage_based', 'business', 'ent26', 'enterprise_cbp_automation', 'enterprise_cbp_usage_based', 'enterprise', 'edu', 'edu_plus', 'edu_pro', 'unknown'], 'type': 'string'}, 'RateLimitReachedType': {'enum': ['rate_limit_reached', 'workspace_owner_credits_depleted', 'workspace_member_credits_depleted', 'workspace_owner_usage_limit_reached', 'workspace_member_usage_limit_reached'], 'type': 'string'}, 'RateLimitSnapshot': {'properties': {'credits': {'anyOf': [{'$ref': '#/definitions/CreditsSnapshot'}, {'type': 'null'}]}, 'individualLimit': {'anyOf': [{'$ref': '#/definitions/SpendControlLimitSnapshot'}, {'type': 'null'}]}, 'limitId': {'type': ['string', 'null']}, 'limitName': {'type': ['string', 'null']}, 'normalModelSlug': {'description': 'Normal model whose display name and reasoning options describe this quota alias.', 'type': ['string', 'null']}, 'planType': {'anyOf': [{'$ref': '#/definitions/PlanType'}, {'type': 'null'}]}, 'primary': {'anyOf': [{'$ref': '#/definitions/RateLimitWindow'}, {'type': 'null'}]}, 'rateLimitReachedType': {'anyOf': [{'$ref': '#/definitions/RateLimitReachedType'}, {'type': 'null'}]}, 'secondary': {'anyOf': [{'$ref': '#/definitions/RateLimitWindow'}, {'type': 'null'}]}, 'spendControlReached': {'description': 'Backend-reported spend-control state. `None` is unavailable, not a sparse-update recovery.', 'type': ['boolean', 'null']}}, 'type': 'object'}, 'RateLimitWindow': {'properties': {'resetsAt': {'format': 'int64', 'type': ['integer', 'null']}, 'usedPercent': {'format': 'int32', 'type': 'integer'}, 'windowDurationMins': {'format': 'int64', 'type': ['integer', 'null']}}, 'required': ['usedPercent'], 'type': 'object'}, 'SpendControlLimitSnapshot': {'properties': {'limit': {'type': 'string'}, 'remainingPercent': {'format': 'int32', 'type': 'integer'}, 'resetsAt': {'format': 'int64', 'type': 'integer'}, 'used': {'type': 'string'}}, 'required': ['limit', 'remainingPercent', 'resetsAt', 'used'], 'type': 'object'}}, 'description': 'Sparse rolling rate-limit update.\n\nClients should merge available values into the most recent `account/rateLimits/read` response or refetch that snapshot. Nullable account metadata may be unavailable in a rolling update and does not clear a previously observed value.', 'properties': {'rateLimits': {'$ref': '#/definitions/RateLimitSnapshot'}}, 'required': ['rateLimits'], 'title': 'AccountRateLimitsUpdatedNotification', 'type': 'object'}


class BoundaryError(Exception):
    """Only fixed diagnostics and validated model identifiers cross the boundary."""
    def __init__(self, message: str, identity: Any = None):
        super().__init__(message)
        self.identity = identity
        self.usage = None
        self.usage_partial = True
        self.resolved_model = None


def failure_category(message: str) -> str:
    if re.search(r'timeout|timed out|transport fail(?:ed|ure)', message, re.I):
        return 'transport'
    if any(text in message for text in ('model or effort mismatch', 'model rerouted', 'actual settings changed')):
        return 'identity'
    if any(text in message for text in ('tool or', 'server request forbidden', 'unsupported event: error', 'single-inference raw evidence')):
        return 'protocol'
    if message.startswith('ERROR: Usage limit'):
        return 'quota'
    if any(text in message for text in ('effective ', ' config', 'MCP server ID', 'config inventory', 'process cleanup', 'feature controls')):
        return 'environment'  # Explicit observed local control/config/cleanup violations.
    return 'unclassified'


@contextmanager
def native_config_home(cwd: Path):
    """Reference the one native auth file; never copy tokens or implement refresh."""
    source = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'auth.json'
    if not source.is_file():
        raise BoundaryError('native auth file unavailable for clean config')
    source = source.resolve()
    environment = {k: v for k, v in os.environ.items()
                   if not k.upper().startswith(('CODEX_', 'OPENAI_', 'CLAUDE_', 'ANTHROPIC_'))
                   and k.upper() != 'CLAUDECODE'}
    with tempfile.TemporaryDirectory(prefix='router-bench-native-home-', dir=cwd) as directory:
        link = Path(directory) / 'auth.json'
        try:
            try:
                link.symlink_to(source)
                same = os.path.samefile(link, source)
            except OSError:
                raise BoundaryError('native auth reference unavailable for clean config') from None
            if not same:
                raise BoundaryError('native auth reference verification failed')
            environment['CODEX_HOME'] = directory
            yield environment
        finally:
            # Unlink the reference before recursive cleanup; never touch its target.
            if link.is_symlink():
                link.unlink()


def verify_clean_layers(response: dict[str, Any]) -> None:
    """No instruction-bearing personal/system/project configuration may survive."""
    layers = response.get('layers')
    if not isinstance(layers, list):
        raise BoundaryError('clean config layers unavailable')
    for layer in layers:
        if not isinstance(layer, dict) or not isinstance(layer.get('name'), dict) or not isinstance(layer.get('config'), dict):
            raise BoundaryError('clean config layer malformed')
        if layer['name'].get('type') != 'sessionFlags' and layer['config']:
            raise BoundaryError('nonempty native config layer forbidden')


def quota_diagnostic(error: Any) -> str | None:
    """Extract only a fixed refusal classification and a validated reset."""
    if not isinstance(error, dict) or not isinstance(error.get('message'), str):
        return None
    message = error['message']
    if not re.search(r"(?i)(usage limit (?:reached|exceeded)|you(?:'ve| have) hit your usage limit|rate limit (?:reached|exceeded)|\brate_limit_(?:exceeded|error)\b|quota exceeded|too many requests|workspace is out of credits|hit your spend cap)", message):
        return None
    safe = 'ERROR: Usage limit reached'
    match = re.search(r'(?i)(?:resets? at|resets?_at|try again at)\s*[=:]?\s*([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:Z|[+-][0-9]{2}:[0-9]{2})|[0-9]{10})(?![0-9])', message)
    if match:
        try:
            value = match[1]
            reset = datetime.fromtimestamp(int(value), timezone.utc) if value.isdigit() else datetime.fromisoformat(value.replace('Z', '+00:00'))
            safe += '; resets at ' + reset.astimezone(timezone.utc).isoformat()
        except (ValueError, OverflowError, OSError):
            pass
    return safe


def model_identity(value: Any) -> str | None:
    return value if isinstance(value, str) and re.fullmatch(r'gpt-[0-9][a-z0-9.-]{0,60}', value) else None



def controls(server_ids: list[str]) -> dict[str, Any]:
    result: dict[str, Any] = {f'features.{s}': False for s in SOURCES}
    result.update({'forced_login_method': 'chatgpt', 'web_search': 'disabled',
                   'cli_auth_credentials_store': 'file',
                   'project_doc_max_bytes': 0, 'agents.enabled': False,
                   'tools.experimental_request_user_input.enabled': False,
                   'developer_instructions': '', 'instructions': ''})
    for name in server_ids:
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', name):
            raise BoundaryError('unsupported MCP server ID component')
        result[f'mcp_servers.{name}.enabled'] = False
    return result


def inventory(response: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    config = response.get('config')
    if not isinstance(config, dict):
        raise BoundaryError('unsupported effective config')
    servers = config.get('mcp_servers', {})
    if not isinstance(servers, dict) or any(not isinstance(v, dict) for v in servers.values()):
        raise BoundaryError('malformed MCP config')
    # Values, including layers and secrets, remain in memory only.
    if len(servers) > 128 or len(response.get('layers', []) or []) > 64:
        raise BoundaryError('config inventory limit')
    # The typed ConfigRead response omits this internal ToolsConfig field.
    # Verify its explicit session-layer value; never infer a missing default.
    tools = config.get('tools', {})
    if isinstance(tools, dict) and 'experimental_request_user_input' not in tools:
        layers = response.get('layers', [])
        session = [x for x in layers if isinstance(x, dict) and x.get('name') == {'type':'sessionFlags'}]
        if len(session) == 1:
            raw_tools = session[0].get('config', {}).get('tools', {})
            input_control = raw_tools.get('experimental_request_user_input') if isinstance(raw_tools, dict) else None
            if isinstance(input_control, dict) and set(input_control) == {'enabled'} and input_control['enabled'] is False:
                config = dict(config, tools=dict(tools, experimental_request_user_input={'enabled':False}))
    return config, list(servers)


def verify(config: dict[str, Any], expected_ids: list[str]) -> None:
    features = config.get('features')
    if not isinstance(features, dict) or any(features.get(s) is not False for s in SOURCES):
        raise BoundaryError('effective feature controls unsupported or enabled')
    if config.get('agents', {}).get('enabled') is not False or config.get('tools', {}).get('experimental_request_user_input', {}).get('enabled') is not False:
        raise BoundaryError('effective agent or input controls failed')
    if config.get('forced_login_method') != 'chatgpt' or config.get('web_search') != 'disabled':
        raise BoundaryError('effective auth or web control failed')
    if type(config.get('project_doc_max_bytes')) is not int or config['project_doc_max_bytes'] != 0:
        raise BoundaryError('effective project document control failed')
    if any(config.get(key) != '' for key in ('developer_instructions', 'instructions')):
        raise BoundaryError('effective instruction controls failed')
    servers = config.get('mcp_servers', {})
    if set(servers) != set(expected_ids) or any(v.get('enabled') is not False for v in servers.values()):
        raise BoundaryError('effective MCP controls failed')
    providers = config.get('model_providers', {})
    if not isinstance(providers, dict) or any(not isinstance(v, dict) for v in providers.values()):
        raise BoundaryError('malformed provider config')
    if config.get('model_provider') not in (None, 'openai') or config.get('model_catalog_json') or providers.get('openai'):
        raise BoundaryError('alternate provider or catalogue configured')


def usage(last: Any) -> dict[str, int] | None:
    names = ('inputTokens', 'cachedInputTokens', 'cacheWriteInputTokens',
             'outputTokens', 'reasoningOutputTokens', 'totalTokens')
    if not isinstance(last, dict):
        return None
    values = tuple(last.get(k, 0) if k == 'cacheWriteInputTokens' else last.get(k) for k in names)
    if any(type(value) is not int or value < 0 for value in values):
        return None
    i, c, w, o, r, total = values
    if c + w > i or r > o or total != i + o:
        return None
    return {'input': i - c - w, 'cached_input': c, 'cache_write': w, 'output': o}


class Server:
    def __init__(self, command: list[str], overrides: dict[str, Any], cwd: Path, deadline: float, environment: dict[str, str] | None = None):
        args = command + ['app-server']
        for key, value in overrides.items():
            args += ['-c', f'{key}={json.dumps(value, ensure_ascii=False)}']
        options: dict[str, Any] = {}
        if os.name == 'nt':
            options['creationflags'] = subprocess.CREATE_NO_WINDOW
        else:
            options['start_new_session'] = True
        self.process = subprocess.Popen(args, cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        env=environment,
                                        **options)
        self.deadline = deadline
        self.messages: queue.Queue[str] = queue.Queue(maxsize=64)
        self.writers: list[threading.Thread] = []
        self.next_id = 0
        self.controls_verified = False
        self.image_paths: frozenset[str] = frozenset()
        self.events: list[dict[str, Any]] = []
        self.stopping = threading.Event()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self) -> None:
        assert self.process.stdout
        while not self.stopping.is_set():
            line = self.process.stdout.readline(1024 * 1024 + 1)
            if len(line) > 1024 * 1024:
                line = '{}'
            else:
                try:
                    line = line.decode('utf-8')
                except UnicodeDecodeError:
                    line = '{}'
            while not self.stopping.is_set():
                try:
                    self.messages.put(line, timeout=.05)
                    break
                except queue.Full:
                    if time.monotonic() >= self.deadline:
                        return
            if not line:
                return

    def send(self, message: dict[str, Any]) -> None:
        data = json.dumps(message, ensure_ascii=False) + '\n'
        if len(data.encode('utf-8')) > 1024 * 1024:
            raise BoundaryError('stdin message limit')
        errors = []
        def write():
            try:
                self.process.stdin.write(data.encode('utf-8'))
                self.process.stdin.flush()
            except (OSError, ValueError):
                errors.append(True)
        writer = threading.Thread(target=write, daemon=True)
        self.writers.append(writer)
        writer.start()
        writer.join(max(0, self.deadline-time.monotonic()))
        if writer.is_alive() or errors:
            raise BoundaryError('stdin timeout or failure')

    def receive(self) -> dict[str, Any]:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise BoundaryError('Codex timeout')
        try:
            line = self.messages.get(timeout=remaining)
        except queue.Empty:
            raise BoundaryError('Codex timeout') from None
        if not line: raise BoundaryError('server closed before protocol response')
        try:
            message = json.loads(line)
        except (ValueError, TypeError):
            raise BoundaryError('malformed protocol message') from None
        if not isinstance(message, dict):
            raise BoundaryError('malformed protocol message')
        if 'method' in message:
            if not isinstance(message.get('params'), dict):
                raise BoundaryError('malformed event parameters')
            if 'id' in message:
                # No fulfillment, approval or tool result is sent back.
                raise BoundaryError('server request forbidden')
            method = message['method']
            if method == 'account/updated':
                params = message['params']
                if (set(params) - {'authMode', 'planType'} or params.get('authMode') != 'chatgpt'
                        or params.get('planType') not in (None, *QUOTA_SCHEMA['definitions']['PlanType']['enum'])):
                    raise BoundaryError('account authentication changed or malformed')
                return message
            if method == 'account/rateLimits/updated':
                if not schema_valid(message['params'], QUOTA_SCHEMA, QUOTA_SCHEMA):
                    raise BoundaryError('malformed quota telemetry')
                return message
            if method == 'warning':
                params = message['params']
                if (not self.controls_verified or set(params) != {'threadId', 'message'}
                        or params.get('message') != DISABLED_HOST_WARNING):
                    raise BoundaryError('unsupported event: warning')
                required_id(params.get('threadId'))
                return message
            if method == 'remoteControl/status/changed':
                if message.get('params', {}).get('status') != 'disabled':
                    raise BoundaryError('remote control not disabled')
                return message
            if method == 'model/rerouted':
                required_id(message.get('params', {}).get('threadId'))
                required_id(message.get('params', {}).get('turnId'))
                return message
            if method == 'error':
                raise BoundaryError(quota_diagnostic(message['params'].get('error')) or 'unsupported event: error')
            if method not in BENIGN:
                if method in ('configWarning', 'warning', 'error', 'account/rateLimits/updated', 'mcpServer/startupStatus/updated'):
                    raise BoundaryError('unsupported event: ' + method)
                raise BoundaryError('unsupported event: ' + (method if method in json.loads(Path(__file__).with_name('appserver-methods.json').read_text()) else 'UNKNOWN_SCHEMA_METHOD'))
            if method in ('item/started', 'item/completed'):
                if not valid_item(message.get('params', {}).get('item'), self.image_paths):
                    raise BoundaryError('tool or unsupported item forbidden')
        return message

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self.next_id += 1
        request_id = self.next_id
        self.send({'id': request_id, 'method': method, 'params': params})
        while True:
            message = self.receive()
            if 'method' in message:
                if method in ('initialize', 'config/read') and message['method'] not in ('remoteControl/status/changed', 'account/updated'):
                    raise BoundaryError('unexpected startup event')
                if len(self.events) >= 64: raise BoundaryError('event buffer limit')
                self.events.append(message)
                continue
            if message.get('id') != request_id or 'error' in message or not isinstance(message.get('result'), dict):
                raise BoundaryError(quota_diagnostic(message.get('error')) or 'protocol response ID or error')
            return message['result']

    def initialize(self) -> None:
        self.request('initialize', {'clientInfo': {'name': 'router_bench', 'version': '1'},
                                    'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized'})

    def close(self) -> None:
        failed = False
        self.stopping.set()
        try:
            if os.name == 'nt':
                # Kill the tree even if its parent exited; descendants may hold pipes.
                try:
                    killed = subprocess.run(['taskkill', '/PID', str(self.process.pid), '/T', '/F'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        creationflags=subprocess.CREATE_NO_WINDOW, timeout=3)
                    failed = killed.returncode != 0 and self.process.poll() is None
                except (OSError, subprocess.TimeoutExpired):
                    failed = True
            else:
                try: os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                except OSError: failed = True
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait(timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            failed = True
        finally:
            self.reader.join(timeout=1)
            # Closing buffered stdin while a writer owns its lock can block forever.
            # Terminating the child unblocks the writer first.
            for writer in getattr(self, 'writers', []):
                writer.join(timeout=1)
                failed = failed or writer.is_alive()
            for stream in (self.process.stdin, self.process.stdout):
                try:
                    if stream and not self.reader.is_alive() and not any(w.is_alive() for w in self.writers): stream.close()
                except (OSError, ValueError): failed = True
            failed = failed or self.reader.is_alive()
        if failed: raise BoundaryError('process cleanup failed')


def run(command: list[str], request: dict[str, Any], cwd: Path,
        timeout_ms: int, *, probe_only: bool = False) -> dict[str, Any]:
    with native_config_home(cwd) as environment:
        return _run(command, request, cwd, timeout_ms, environment, probe_only=probe_only)


def _run(command: list[str], request: dict[str, Any], cwd: Path,
         timeout_ms: int, environment: dict[str, str], *, probe_only: bool = False) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_ms / 1000
    server = Server(command, controls([]), cwd, deadline, environment)
    try:
        server.initialize()
        initial = server.request('config/read', {'cwd': str(cwd), 'includeLayers': True})
        verify_clean_layers(initial)
        _, ids = inventory(initial)
    finally:
        server.close()
    server = Server(command, controls(ids), cwd, deadline, environment)
    server.image_paths = frozenset(str(Path(p).resolve()) for p in request.get('images', []))
    measured = None
    cumulative = None
    responses = {}
    pending_error = None
    verified_model = None
    def retained_usage():
        raw = [x for x in responses.values() if x is not None]
        raw_sum = {k: sum(x[k] for x in raw) for k in ('input','cached_input','cache_write','output')} if raw else None
        # Sources overlap: use the stronger observed lower bound, never add them.
        if raw_sum is None: return cumulative
        if cumulative is None: return raw_sum
        return {k: max(raw_sum[k], cumulative[k]) for k in raw_sum}
    try:
        server.initialize()
        effective = server.request('config/read', {'cwd': str(cwd), 'includeLayers': True})
        verify_clean_layers(effective)
        config, actual_ids = inventory(effective)
        verify(config, ids)
        server.controls_verified = True
        if probe_only:
            return {'status': 'verified', 'server_count': len(actual_ids)}
        model, effort = request['model'], request['effort']
        thread = server.request('thread/start', {'cwd': str(cwd), 'model': model,
            # Replace coding-agent workflow instructions, not the enforcement boundary.
            # Tools and multi-inference answers still fail closed below.
            'baseInstructions': BENCH_INSTRUCTIONS,
            'developerInstructions': '',
            'allowProviderModelFallback': False, 'ephemeral': True, 'experimentalRawEvents': True, 'environments': [],
            'dynamicTools': [], 'selectedCapabilityRoots': [],
            'config': {'model_reasoning_effort': effort}, 'approvalPolicy': 'never'})
        if thread.get('model') != model or thread.get('reasoningEffort') != effort or thread.get('modelProvider') != 'openai':
            raise BoundaryError('actual model or effort mismatch', {'actual_model':model_identity(thread.get('model')), 'comparison_valid':False})
        verified_model = model
        thread_id = required_id(thread.get('thread', {}).get('id'))
        if thread.get('thread', {}).get('turns') not in (None, []): raise BoundaryError('unexpected thread history')
        inputs = [{'type': 'text', 'text': request['prompt']}]
        for image in request.get('images', []):
            inputs.append({'type': 'localImage', 'path': str(Path(image).resolve())})
        started = server.request('turn/start', {'threadId': thread_id, 'environments': [],
            'model': model, 'effort': effort, 'input': inputs})
        turn_id = required_id(started.get('turn', {}).get('id'))
        validate_turn(started['turn'], server.image_paths)
        final = None
        measured = None
        responses = {}
        raw_invalid = False
        usage_invalid = False
        raw_answer = None
        cumulative_seen = False
        host_warning_seen = False
        while True:
            event = server.events.pop(0) if server.events else server.receive()
            if 'method' not in event:
                raise BoundaryError('unexpected response')
            method, params = event['method'], event.get('params', {})
            if method in ('remoteControl/status/changed', 'account/rateLimits/updated', 'account/updated'): continue
            if method == 'warning':
                if params.get('threadId') != thread_id or host_warning_seen:
                    raise BoundaryError('stale or duplicate disabled-host warning')
                host_warning_seen = True
                continue
            if method == 'thread/started':
                payload = params.get('thread', {})
                if payload.get('id') != thread_id or payload.get('turns') not in (None, []): raise BoundaryError('stale or malformed thread event')
                continue
            if params.get('threadId') != thread_id or (method not in ('thread/status/changed', 'thread/settings/updated') and params.get('turnId', params.get('turn', {}).get('id')) != turn_id):
                raise BoundaryError('stale thread or turn event')
            if method == 'model/rerouted':
                raise BoundaryError('model rerouted; comparison invalid', {'from_model': model_identity(params.get('fromModel')), 'to_model': model_identity(params.get('toModel')), 'comparison_valid': False})
            if method.startswith('item/') and method not in ('item/started', 'item/completed'):
                required_id(params.get('itemId'))
                if method != 'item/reasoning/summaryPartAdded' and not isinstance(params.get('delta'), str):
                    raise BoundaryError('malformed delta')
                for key in ('summaryIndex', 'contentIndex'):
                    if key in params and type(params[key]) is not int:
                        raise BoundaryError('malformed reasoning index')
                if method in ('item/reasoning/summaryPartAdded', 'item/reasoning/summaryTextDelta') and type(params.get('summaryIndex')) is not int:
                    raise BoundaryError('missing reasoning index')
                if method == 'item/reasoning/textDelta' and type(params.get('contentIndex')) is not int:
                    raise BoundaryError('missing reasoning content index')
            if method == 'thread/status/changed':
                status = params.get('status')
                if not isinstance(status, dict) or status.get('type') not in ('notLoaded', 'idle', 'active') or (status.get('type') == 'active' and status.get('activeFlags') != []):
                    raise BoundaryError('unsupported thread status')
            if method == 'turn/started': validate_turn(params.get('turn'), server.image_paths)
            if method == 'thread/settings/updated':
                settings = params.get('threadSettings', {})
                if settings.get('model') != model or settings.get('effort') != effort or settings.get('modelProvider') != 'openai':
                    raise BoundaryError('actual settings changed; comparison invalid', {'actual_model':model_identity(settings.get('model')), 'comparison_valid':False})
            if method == 'rawResponseItem/completed':
                if set(params) != {'threadId','turnId','item'}: raw_invalid = True
                item = params.get('item')
                if not valid_raw_item(item, images_sent=bool(server.image_paths)):
                    raw_invalid = True
                elif item.get('type') == 'message' and item.get('role') == 'assistant' and item.get('phase') == 'final_answer':
                    text = ''.join(x['text'] for x in item['content'])
                    if raw_answer is not None: raw_invalid = True
                    raw_answer = text
            if method == 'rawResponse/completed':
                if set(params) - {'threadId','turnId','responseId','usage','usageMetadata'}: raw_invalid = True
                if len(responses) >= 128: raise BoundaryError('response identity limit')
                response_id = required_id(params.get('responseId'))
                raw_usage = params.get('usage')
                if response_id in responses or not isinstance(raw_usage, dict):
                    raw_invalid = True
                else:
                    responses[response_id] = usage(raw_usage)
                    if responses[response_id] is None: usage_invalid = True
                    measured = retained_usage()
            if method == 'thread/tokenUsage/updated':
                token_usage = params.get('tokenUsage', {})
                total = token_usage.get('total')
                cumulative_seen = True
                candidate = usage(total)
                if candidate is None:
                    usage_invalid = True
                    continue
                if cumulative is not None and any(candidate[k] < cumulative[k] for k in cumulative):
                    raise BoundaryError('cumulative usage regressed')
                cumulative = candidate
                measured = retained_usage()
            if method == 'item/completed' and params['item']['type'] == 'agentMessage':
                item = params['item']
                if item.get('phase') == 'final_answer':
                    if final is not None or not isinstance(item.get('text'), str):
                        raise BoundaryError('invalid final answer')
                    final = item['text']
            if method == 'turn/completed':
                turn = params.get('turn', {})
                validate_turn(turn, server.image_paths)
                if turn.get('id') != turn_id or turn.get('status') != 'completed' or turn.get('error') is not None or final is None:
                    raise BoundaryError(quota_diagnostic(turn.get('error')) or 'turn failed or final answer missing')
                if raw_invalid or len(responses) != 1 or raw_answer != final:
                    raise BoundaryError('single-inference raw evidence missing or ambiguous')
                raw_measured = next(iter(responses.values()))
                if usage_invalid and retained_usage() is not None:
                    raise BoundaryError('usage observations incomplete or inconsistent')
                if cumulative_seen and cumulative != raw_measured:
                    raise BoundaryError('raw and cumulative usage disagree')
                return {'status': 'ok', 'answer': final, 'usage': measured,
                        'usage_partial': False, 'resolved_model': model, 'resolved_effort': effort,
                        'tools': 'host disabled; unsupported attempts rejected'}
    except BoundaryError as error:
        pending_error = error
        error.usage = retained_usage()
        error.resolved_model = verified_model if not (isinstance(error.identity, dict) and error.identity.get('comparison_valid') is False) else None
        raise
    except Exception:
        pending_error = BoundaryError('transport failure')
        pending_error.usage = retained_usage()
        pending_error.resolved_model = verified_model
        raise pending_error from None
    finally:
        try:
            server.close()
        except Exception as error:
            cleanup = error if isinstance(error, BoundaryError) else BoundaryError('process cleanup failed')
            cleanup.usage = retained_usage()
            if pending_error is None:
                raise cleanup from None
            # Keep the original sanitized refusal/diagnostic and its known usage.




def schema_valid(value: Any, schema: dict, root: dict) -> bool:
    if '$ref' in schema:
        return schema_valid(value, root['definitions'][schema['$ref'].split('/')[-1]], root)
    if 'anyOf' in schema:
        return any(schema_valid(value, child, root) for child in schema['anyOf'])
    types = schema.get('type', [])
    if isinstance(types, str): types = [types]
    matches = {'null': value is None, 'object': isinstance(value, dict),
               'string': isinstance(value, str), 'boolean': type(value) is bool,
               'integer': type(value) is int}
    if types and not any(matches.get(t, False) for t in types): return False
    if 'enum' in schema and value not in schema['enum']: return False
    if isinstance(value, dict):
        properties = schema.get('properties', {})
        if set(value) - set(properties) or any(k not in value for k in schema.get('required', [])): return False
        return all(schema_valid(v, properties[k], root) for k,v in value.items())
    return True


def valid_raw_content(part: Any, role: Any, images_sent: bool) -> bool:
    if not isinstance(part, dict): return False
    if part.get('type') in ('input_text', 'output_text'):
        return isinstance(part.get('text'), str)
    # A localImage input arrives in the raw user message as an input_image data URL
    # (codex-rs models.rs ContentItem::InputImage). Only a turn that sent images may carry one.
    if part.get('type') == 'input_image':
        return (images_sent and role == 'user'
            and not (set(part) - {'type', 'image_url', 'detail'})
            and isinstance(part.get('image_url'), str) and part['image_url'].startswith('data:image/')
            and (part.get('detail') is None or isinstance(part.get('detail'), str)))
    return False


def valid_raw_item(item: Any, images_sent: bool = False) -> bool:
    if not isinstance(item, dict): return False
    if item.get('type') == 'message':
        return (isinstance(item.get('id'), str) and bool(item['id'])
            and not (set(item) - {'type','id','role','content','phase','end_turn','internal_chat_message_metadata_passthrough'})
            and item.get('role') in ('system', 'developer', 'user', 'assistant')
            and item.get('phase') in (None, 'commentary', 'final_answer')
            and isinstance(item.get('content'), list)
            and all(valid_raw_content(x, item.get('role'), images_sent) for x in item['content']))
    if item.get('type') == 'reasoning':
        return (isinstance(item.get('id'), str) and bool(item['id'])
            and isinstance(item.get('summary'), list)
            and all(isinstance(x, dict) and x.get('type') == 'summary_text'
                    and isinstance(x.get('text'), str) for x in item['summary'])
            # Codex rust-v0.160.0 models.rs ResponseItem::Reasoning: Option<String>.
            # Opaque ciphertext is data; it is never decoded or executed.
            and (item.get('encrypted_content') is None or isinstance(item.get('encrypted_content'), str)))
    return False


def required_id(value: Any) -> str:
    if not isinstance(value, str) or not value:
        raise BoundaryError('required protocol ID missing')
    return value


def valid_item(item: Any, image_paths: frozenset[str] = frozenset()) -> bool:
    if not isinstance(item, dict) or not isinstance(item.get('id'), str) or not item['id']:
        return False
    kind = item.get('type')
    if kind == 'agentMessage':
        return isinstance(item.get('text'), str) and item.get('phase') in (None, 'commentary', 'final_answer') and not item.get('questions') and not item.get('memoryCitation')
    if kind == 'reasoning':
        return all(isinstance(item.get(k, []), list) and all(isinstance(x, str) for x in item.get(k, [])) for k in ('summary','content'))
    if kind == 'userMessage':
        return isinstance(item.get('content'), list) and all(isinstance(x, dict) and (
            (x.get('type') == 'text' and isinstance(x.get('text'), str)) or
            (x.get('type') == 'localImage' and isinstance(x.get('path'), str) and x['path'] in image_paths)
        ) for x in item['content'])
    return False


def validate_turn(turn: Any, image_paths: frozenset[str] = frozenset()) -> None:
    if not isinstance(turn, dict) or not isinstance(turn.get('items'), list) or any(not valid_item(i, image_paths) for i in turn['items']):
        raise BoundaryError('tool or malformed turn payload forbidden')
    required_id(turn.get('id'))


if __name__ == '__main__':
    import sys
    try:
        line = sys.stdin.readline(1024 * 1024 + 1)
        if len(line.encode('utf-8')) > 1024 * 1024:
            raise BoundaryError('stdin message limit')
        payload = json.loads(line)
        result = run(payload['command'], payload['request'], Path(payload['cwd']), payload['timeout_ms'])
    except BoundaryError as error:
        result = {'status':'unknown', 'failure_category':failure_category(str(error)), 'root_cause':'unverified' if failure_category(str(error)) in ('protocol','transport','unclassified') else 'observed boundary failure', 'detail':str(error), 'identity':error.identity, 'resolved_model':error.resolved_model, 'usage':error.usage, 'usage_partial':error.usage_partial}
    except Exception:
        result = {'status':'unknown', 'failure_category':'unclassified', 'root_cause':'unverified', 'detail':'transport or cleanup failure'}
    print(json.dumps(result, ensure_ascii=False))
