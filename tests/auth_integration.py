"""Exercise the setup gate, legacy migrations and sign-in against isolated containers."""
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = os.environ.get('TEST_IMAGE', 'clash-meta-review:local')
SUBSCRIPTION = 'http://127.0.0.1:18888/subscription.yaml'
USERNAME = 'clash-owner'
PASSWORD = 'test-设置-Secret!'
NEW_PASSWORD = ' 更换密码 with spaces '


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()


def eventually(check, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (urllib.error.URLError, OSError, ValueError):
            pass
        time.sleep(0.25)
    raise AssertionError('Condition did not complete within timeout')


def basic(username, password):
    return 'Basic ' + base64.b64encode(f'{username}:{password}'.encode()).decode()


@contextmanager
def container_with_data(data, *environment):
    container = docker(
        'run', '-d', '--name', 'clash-auth-' + uuid.uuid4().hex[:8],
        '-p', '127.0.0.1::9090', '-v', f'{data}:/root/.config/clash',
        '-v', f'{ROOT / "tests"}:/opt/tests:ro', '-e', 'GEODATA_AUTO_UPDATE=false',
        '-e', 'SUBSCR_RETRY=0', '-e', 'SUBSCR_DOWNLOAD_MAX_TIME=3', '-e', 'SUBSCR_CONNECT_TIMEOUT=1',
        '-e', 'BUILTIN_RULE_FILE=/opt/tests/minimal-template.yaml', *environment, IMAGE,
    )
    try:
        yield container
    except Exception:
        print(docker('logs', '--tail', '24', container), flush=True)
        raise
    finally:
        docker('rm', '-f', container)


def portal_client(container):
    origin = 'http://' + docker('port', container, '9090/tcp')

    def request(path, auth='', payload=None, method=None):
        headers = {'Authorization': auth} if auth else {}
        if payload is not None:
            headers['Content-Type'] = 'application/json'
        body = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(origin + path, body, headers, method=method or ('PUT' if body else 'GET'))
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def state(expected, account=None, subscription=None):
        def check():
            code, body = request('/setup/status.json')
            if code != 200:
                return False
            value = json.loads(body)
            return (value['state'] == expected and (account is None or value['needsAccount'] is account)
                    and (subscription is None or value['needsSubscription'] is subscription))

        eventually(check)

    def task(namespace, payload, auth, next_auth=None):
        ident = uuid.uuid4().hex
        path = f'/setup/requests/{ident}' if namespace == 'setup' else f'/requests/{namespace}/{ident}'
        results = f'/setup/results/{ident}.json' if namespace == 'setup' else f'/tasks/{ident}.json'
        assert request(path, auth, payload)[0] in (201, 204), path

        def read_result():
            for credentials in (auth, next_auth) if next_auth else (auth,):
                code, body = request(results, credentials)
                if code == 200:
                    result = json.loads(body)
                    if 'ok' in result or result.get('state') in ('success', 'failed'):
                        return result
            return False

        return eventually(read_result)

    return origin, request, state, task


def assert_gate(request, auth=''):
    for path in ('/connection.json', '/settings.json', '/subscriptions.json', '/status.json',
                 '/subscription-info.json', '/subscription-validate.json', '/latency-browser.json',
                 '/latency-router.json', '/tasks/example.json', '/version', '/ui/metacubexd/', '/setup-status.json'):
        assert request(path, auth)[0] == 403, path
    for path in ('/requests/updates/blocked', '/requests/password/blocked', '/settings.json', '/subscriptions.json'):
        assert request(path, auth, {})[0] == 403, path


rendered = subprocess.check_output(['docker', 'compose', 'config', '--format', 'json'], cwd=ROOT, text=True)
services = json.loads(rendered)['services']
assert services.keys() == {'clash'}
assert 'build' not in services['clash']
assert 'PORTAL_AUTH_ENABLED' not in services['clash']['environment']
print('PASS: public Compose declares only the published service', flush=True)

with tempfile.TemporaryDirectory(prefix='clash-setup-fresh-') as directory:
    data = Path(directory)
    with container_with_data(data) as container:
        origin, request, state, task = portal_client(container)
        state('pending', True, True)
        assert request('/')[0] == 200
        assert request('/setup.css')[0] == request('/setup.js')[0] == 200
        assert docker('exec', container, 'bash', '/opt/scripts/healthcheck.sh') == ''
        assert_gate(request)
        credentials = {'username': USERNAME, 'password': PASSWORD, 'confirmation': PASSWORD}
        assert task('setup', credentials, '')['state'] == 'failed'
        docker('exec', '-d', container, 'python3', '/opt/tests/fixture_server.py')
        assert task('setup', {**credentials, 'url': SUBSCRIPTION.replace('subscription.yaml', 'broken')}, '')['state'] == 'failed'
        assert_gate(request)
        assert 'PORTAL_ADMIN_USERNAME' not in (data / '.env').read_text()
        assert json.loads((data / 'subscriptions.json').read_text())['urls'] == []

        if os.environ.get('RUN_BROWSER_TESTS') == '1':
            subprocess.run(['node', str(ROOT / 'tests/browser.cjs')], check=True,
                           env={**os.environ, 'PORTAL_URL': origin, 'PORTAL_USERNAME': USERNAME,
                                'PORTAL_PASSWORD': PASSWORD, 'PORTAL_SUBSCRIPTION': SUBSCRIPTION})
        else:
            assert task('setup', {**credentials, 'url': SUBSCRIPTION}, '')['state'] == 'success'
        state('ready', False, False)
        auth = basic(USERNAME, PASSWORD)
        assert request('/setup/requests/second', payload=credentials)[0] == 409
        assert request('/connection.json', basic('admin', PASSWORD))[0] == 403
        assert request('/connection.json', auth)[0] == 200
        env_text = (data / '.env').read_text()
        assert PASSWORD not in env_text
        assert (data / '.env').stat().st_mode & 0o777 == 0o600
        assert SUBSCRIPTION in env_text
        new_auth = basic(USERNAME, NEW_PASSWORD)
        assert task('password', {'currentPassword': PASSWORD, 'newPassword': NEW_PASSWORD,
                                 'confirmPassword': 'different'}, auth)['state'] == 'failed'
        assert task('password', {'currentPassword': PASSWORD, 'newPassword': NEW_PASSWORD,
                                 'confirmPassword': NEW_PASSWORD}, auth, new_auth)['state'] == 'success'
        assert request('/connection.json', auth)[0] == 403
        assert request('/connection.json', new_auth)[0] == 200
        logs = docker('logs', container)
        assert all(value not in logs for value in (PASSWORD, NEW_PASSWORD))
        print('PASS: direct setup, failed import, protected routes and password rotation', flush=True)

        docker('restart', container)
        _, request, state, _ = portal_client(container)
        state('ready')
        assert request('/connection.json', new_auth)[0] == 200
        assert request('/connection.json', auth)[0] == 403
        assert json.loads(request('/subscriptions.json', new_auth)[1])['urls'] == [SUBSCRIPTION]
        print('PASS: credentials and subscription restored from .env after restart with offline subscription server', flush=True)

with tempfile.TemporaryDirectory(prefix='clash-setup-legacy-') as directory:
    data = Path(directory)
    generated = 'a' * 48
    (data / 'portal-admin.key').write_text(generated + '\n')
    (data / 'portal-auth.json').write_text(json.dumps({'source': 'generated'}))
    old_secret = 'legacy-open-secret'
    (data / 'portal.json').write_text(json.dumps({'secret': old_secret, 'authEnabled': False, 'credentialVersion': 1}))
    (data / 'subscriptions.json').write_text(json.dumps({'active': 0, 'urls': [SUBSCRIPTION]}))
    proxies = data / 'proxies'
    proxies.mkdir()
    (proxies / hashlib.md5(SUBSCRIPTION.encode()).hexdigest()).write_text(
        'mode: global\nproxies: [{name: Test, type: http, server: 127.0.0.1, port: 10000}]\n')
    with container_with_data(data, '-e', 'PORTAL_AUTH_ENABLED=false') as container:
        origin, request, state, task = portal_client(container)
        state('pending', True, False)
        assert_gate(request, basic('admin', generated))
        assert_gate(request, 'Bearer ' + old_secret)
        credentials = {'username': USERNAME, 'password': PASSWORD, 'confirmation': PASSWORD}
        assert task('setup', {**credentials, 'password': '', 'confirmation': ''}, '')['state'] == 'failed'
        state('pending', True, False)
        assert_gate(request)
        if os.environ.get('RUN_BROWSER_TESTS') == '1':
            subprocess.run(['node', str(ROOT / 'tests/browser.cjs')], check=True,
                           env={**os.environ, 'PORTAL_URL': origin, 'PORTAL_USERNAME': USERNAME,
                                'PORTAL_PASSWORD': PASSWORD, 'PORTAL_SETUP_ACCOUNT_ONLY': '1'})
        else:
            assert task('setup', credentials, '')['state'] == 'success'
        state('ready')
        auth = basic(USERNAME, PASSWORD)
        assert json.loads(request('/subscriptions.json', auth)[1])['urls'] == [SUBSCRIPTION]
        assert json.loads(request('/connection.json', auth)[1])['secret'] != old_secret
        assert request('/configs', 'Bearer ' + old_secret)[0] == 401
        print('PASS: legacy passwordless deployment forces new credentials and keeps cached subscriptions', flush=True)

with tempfile.TemporaryDirectory(prefix='clash-setup-yaml-') as directory:
    data = Path(directory) / 'data'
    data.mkdir()
    yaml_path = Path(directory) / '家用.yaml'
    configuration = b'mode: global\nproxies: [{name: Local, type: http, server: 127.0.0.1, port: 10000}]\n'
    yaml_path.write_bytes(configuration + b'# sample comment\n' * 20000)
    credentials = {'username': USERNAME, 'password': PASSWORD, 'confirmation': PASSWORD}
    auth = basic(USERNAME, PASSWORD)

    def upload(name, content):
        return {'upload': {'name': name, 'content': base64.b64encode(content).decode()}}

    with container_with_data(data) as container:
        origin, request, state, task = portal_client(container)
        state('pending', True, True)
        assert request('/requests/uploads/blocked', auth, upload('blocked.yaml', configuration))[0] == 403
        invalid = task('setup', {**credentials, **upload('broken.yaml', b'not a Clash config')}, '')
        assert invalid['state'] == 'failed' and not list((data / 'local-subscriptions').glob('*.yaml'))
        mixed = task('setup', {**credentials, **upload('mixed.yaml', configuration), 'url': SUBSCRIPTION}, '')
        assert mixed['state'] == 'failed'
        if os.environ.get('RUN_BROWSER_TESTS') == '1':
            subprocess.run(['node', str(ROOT / 'tests/browser.cjs')], check=True,
                           env={**os.environ, 'PORTAL_URL': origin, 'PORTAL_USERNAME': USERNAME,
                                'PORTAL_PASSWORD': PASSWORD, 'PORTAL_SETUP_YAML': str(yaml_path)})
        else:
            result = task('setup', {**credentials, **upload(yaml_path.name, yaml_path.read_bytes())}, '')
            assert result['state'] == 'success'
            second = task('uploads', upload('second.yml', configuration), auth)
            assert second['ok'] and second['name'] == 'second.yml'
            first = json.loads(request('/subscriptions.json', auth)[1])['items'][0]
            save_id = uuid.uuid4().hex
            selection = {'active': 1, 'urls': [first['url'], second['url']], 'items': [first, second], 'requestId': save_id}
            assert request('/subscriptions.json', auth, selection)[0] in (201, 204)
            def save_finished():
                code, body = request(f'/tasks/{save_id}.json', auth)
                return code == 200 and json.loads(body).get('state') == 'success'
            eventually(save_finished)
        state('ready')
        subscriptions = json.loads(request('/subscriptions.json', auth)[1])
        saved = subscriptions['items'][0]
        assert saved['name'] == yaml_path.name
        assert saved['url'] == 'local:' + hashlib.sha256(yaml_path.read_bytes()).hexdigest()
        saved_file = data / 'local-subscriptions' / (saved['url'].split(':', 1)[1] + '.yaml')
        assert saved_file.read_bytes() == yaml_path.read_bytes()
        assert saved_file.stat().st_mode & 0o777 == 0o600
        assert request('/requests/uploads/blocked', payload=upload('blocked.yaml', configuration))[0] == 403
        assert request('/local-subscriptions/' + saved_file.name)[0] in (401, 403, 404)
        active_before_restart = subscriptions['urls'][subscriptions['active']]
        docker('restart', container)
        _, request, state, _ = portal_client(container)
        state('ready')
        subscriptions = json.loads(request('/subscriptions.json', auth)[1])
        assert subscriptions['urls'][subscriptions['active']] == active_before_restart
        assert subscriptions['items'][0]['name'] == yaml_path.name
        print('PASS: local YAML validation, private storage, theme continuity and restart persistence', flush=True)
