"""Configures Open WebUI for the local agent through its API.

Runs inside a throwaway container of the Open WebUI image (its own Python, standard library only), started by
`agent configure` (agent.ps1 / agent.sh): nothing to install on the computer. Safe to run again.

Mounted: this repo at /agent (read-only: .env, system-prompt.md, knowledge.conf if present), the projects folder at /projects
(read-only: knowledge files). Passed in: OT_URL, OLLAMA_URL (they differ per OS).
"""
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

BASE = 'http://open-webui:8080'


def load_env(path):
    env = {}
    with open(path, encoding='utf-8-sig') as f:   # -sig and strip(): .env written by Windows PowerShell
        for line in f:
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                key, value = line.split('=', 1)
                env[key.strip()] = value.strip()
    return env


ENV = load_env('/agent/.env')
for key in ('OT_URL', 'OLLAMA_URL'):
    if os.environ.get(key):
        ENV[key] = os.environ[key]
DEFAULT_MODEL = ENV.get('DEFAULT_MODEL', 'gpt-oss:20b')


def call(method, path, body=None, token=None, raw=None, content_type='application/json', missing_ok=False):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        request.add_header('Content-Type', content_type)
    if token:
        request.add_header('Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            text = response.read()
            return json.loads(text) if text else None
    except urllib.error.HTTPError as error:
        if missing_ok and error.code in (401, 404):
            return None
        detail = error.read()[:300].decode(errors='replace')
        sys.exit(f'{method} {path}: HTTP {error.code} {detail}')


def wait_for_webui():
    for _ in range(180):
        try:
            with urllib.request.urlopen(BASE + '/health', timeout=2):
                return
        except Exception:
            time.sleep(1)
    sys.exit('Open WebUI did not answer on /health.')


def sign_in():
    email, password = ENV.get('WEBUI_ADMIN_EMAIL'), ENV.get('WEBUI_ADMIN_PASSWORD')
    if not email or not password:
        sys.exit('WEBUI_ADMIN_EMAIL / WEBUI_ADMIN_PASSWORD missing in .env.')
    request = urllib.request.Request(BASE + '/api/v1/auths/signin', method='POST',
                                     data=json.dumps({'email': email, 'password': password}).encode())
    request.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            user = json.loads(response.read())
    except urllib.error.HTTPError:
        sys.exit('Sign-in failed: put the login of an Open WebUI admin account in .env '
                 '(WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD).')
    if user.get('role') != 'admin':
        sys.exit(f'{email} is not an admin.')
    return user['token']


def set_ollama(token):
    url = ENV['OLLAMA_URL']
    config = call('GET', '/ollama/config', token=token)
    if config.get('OLLAMA_BASE_URLS') == [url] and config.get('ENABLE_OLLAMA_API'):
        print(f'Ollama URL: {url} (unchanged)')
        return
    first = (config.get('OLLAMA_API_CONFIGS') or {}).get('0', {'enable': True, 'connection_type': 'local'})
    call('POST', '/ollama/config/update', token=token, body={
        'ENABLE_OLLAMA_API': True, 'OLLAMA_BASE_URLS': [url], 'OLLAMA_API_CONFIGS': {'0': first}})
    print(f'Ollama URL: {url}')


def set_terminal(token):
    """One terminal connection, named Terminal; returns its id (the Agent model pre-selects it)."""
    url, key = ENV['OT_URL'], ENV['OPEN_TERMINAL_API_KEY']
    connections = call('GET', '/api/v1/configs/terminal_servers', token=token)['TERMINAL_SERVER_CONNECTIONS'] or []
    mine = next((c for c in connections if c.get('name') == 'Terminal' or c.get('url') == url), None)
    if mine is None:
        mine = {'id': str(uuid.uuid4()), 'name': 'Terminal', 'path': '/openapi.json', 'forward_cookies': False,
                'config': {'access_grants': [], 'working_directory_context': True, 'user_shell_tools': 'auto'},
                'server_type': None, 'policy_id': None}
        connections.append(mine)
    mine.update({'enabled': True, 'url': url, 'key': key, 'auth_type': 'bearer'})
    call('POST', '/api/v1/configs/terminal_servers', token=token, body={'TERMINAL_SERVER_CONNECTIONS': connections})
    print(f'Open Terminal: {url}')
    return mine['id']


def set_web_search(token):
    # Only the web part of the settings: the API keeps every field that is not sent.
    call('POST', '/api/v1/retrieval/config/update', token=token, body={'web': {
        'ENABLE_WEB_SEARCH': True, 'WEB_SEARCH_ENGINE': 'searxng',
        'SEARXNG_QUERY_URL': 'http://searxng:8080/search?q=<query>', 'WEB_SEARCH_RESULT_COUNT': 3}})
    print('Web search: SearXNG')


def read_knowledge_conf():
    """knowledge.conf: one knowledge base per line, `Name: pattern, pattern`, paths relative to the projects
    folder, ** for subfolders."""
    bases = []
    path = '/agent/knowledge.conf'
    if not os.path.exists(path):
        print('Knowledge bases: none (to add some, copy knowledge.example.conf to knowledge.conf and list your files)')
        return bases
    with open(path, encoding='utf-8-sig') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or ':' not in line:
                continue
            name, patterns = line.split(':', 1)
            files = []
            for pattern in (p.strip() for p in patterns.split(',') if p.strip()):
                files += sorted(glob.glob(os.path.join('/projects', pattern), recursive=True))
            bases.append((name.strip(), [f for f in dict.fromkeys(files) if os.path.isfile(f)]))
    return bases


def find_knowledge(token, name):
    page = 1
    while True:
        result = call('GET', f'/api/v1/knowledge/?page={page}', token=token)
        for item in result.get('items', []):
            if item.get('name') == name:
                return item
        if not result.get('items') or page * len(result['items']) >= result.get('total', 0):
            return None
        page += 1


def upload(token, path):
    boundary = uuid.uuid4().hex
    name = os.path.relpath(path, '/projects').replace(os.sep, '/')
    with open(path, 'rb') as f:
        content = f.read()
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
            f'Content-Type: text/plain\r\n\r\n').encode() + content + f'\r\n--{boundary}--\r\n'.encode()
    # Processed before answering: file/add refuses files that are not processed yet.
    return call('POST', '/api/v1/files/?process=true&process_in_background=false', token=token, raw=body,
                content_type=f'multipart/form-data; boundary={boundary}')['id']


def sync_knowledge(token):
    """Each knowledge base is emptied and filled again from knowledge.conf. Returns them for the Agent model."""
    attached = []
    for name, files in read_knowledge_conf():
        base = find_knowledge(token, name)
        if base is None:
            base = call('POST', '/api/v1/knowledge/create', token=token,
                        body={'name': name, 'description': 'Synced from knowledge.conf by agent configure'})
        else:
            call('POST', f'/api/v1/knowledge/{base["id"]}/reset', token=token)
        for path in files:
            file_id = upload(token, path)
            call('POST', f'/api/v1/knowledge/{base["id"]}/file/add', token=token, body={'file_id': file_id})
        print(f'Knowledge "{name}": {len(files)} files')
        attached.append({'id': base['id'], 'name': name, 'description': base.get('description', ''),
                         'type': 'collection'})
    return attached


def set_agent_model(token, terminal_id, knowledge):
    with open('/agent/system-prompt.md', encoding='utf-8-sig') as f:
        system = f.read()
    form = {
        'id': 'agent', 'base_model_id': DEFAULT_MODEL, 'name': 'Agent', 'is_active': True,
        'meta': {
            'profile_image_url': '/static/favicon.png',
            'description': 'Local coding agent (set up by agent configure)',
            # Open WebUI's defaults for a new model, plus terminal and memory.
            'capabilities': {'file_context': True, 'vision': True, 'file_upload': True, 'web_search': True,
                             'image_generation': True, 'code_interpreter': True, 'terminal': True,
                             'citations': True, 'status_updates': True, 'memory': True, 'builtin_tools': True},
            'knowledge': knowledge or None,
            'terminalId': terminal_id,   # the terminal is pre-selected in new chats with this model
            # Web Search switched on in new chats: only then does the model get the search_web and fetch_url tools.
            'defaultFeatureIds': ['web_search'],
            'builtinTools': {'web_search': True},
            'tags': [],
        },
        'params': {'system': system, 'function_calling': 'native'},
    }
    exists = call('GET', '/api/v1/models/model?id=agent', token=token, missing_ok=True)
    call('POST', '/api/v1/models/model/update' if exists else '/api/v1/models/create', token=token, body=form)
    print(f'Model "Agent": base {DEFAULT_MODEL}, terminal and web search on, {len(knowledge)} knowledge bases')


def set_default_model(token):
    """New chats open on Agent. The API overwrites every field it is not sent: send back what it has."""
    config = call('GET', '/api/v1/configs/models', token=token) or {}
    if config.get('DEFAULT_MODELS') == 'agent':
        print('Default model: Agent (unchanged)')
        return
    for key in ('DEFAULT_PINNED_MODELS', 'MODEL_ORDER_LIST'):   # required by the form, may be unset
        config.setdefault(key, None)
    config['DEFAULT_MODELS'] = 'agent'
    call('POST', '/api/v1/configs/models', token=token, body=config)
    print('Default model: Agent')


def main():
    wait_for_webui()
    token = sign_in()
    set_ollama(token)
    terminal_id = set_terminal(token)
    set_web_search(token)
    knowledge = sync_knowledge(token)
    set_agent_model(token, terminal_id, knowledge)
    set_default_model(token)
    print('Open WebUI configured.')


main()
