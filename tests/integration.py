"""Run against an isolated container with temporary data and a local subscription server."""
import base64
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
PASSWORD = 'test-password-测试'


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()


def eventually(check, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (urllib.error.URLError, OSError, ValueError):
            pass
        time.sleep(0.3)
    raise AssertionError('Condition did not complete within timeout')


with tempfile.TemporaryDirectory(prefix='clash-integration-') as directory:
    data = Path(directory) / 'data'
    data.mkdir()
    container = docker('run', '-d', '--name', 'clash-test-' + uuid.uuid4().hex[:8],
                       '-p', '127.0.0.1::9090', '-p', '127.0.0.1::9097',
                       '-v', f'{data}:/root/.config/clash', '-v', f'{ROOT / "tests"}:/opt/tests:ro',
                       '-e', f'PORTAL_ADMIN_KEY={PASSWORD}', '-e', 'SUBSCR_RETRY=0',
                       '-e', 'SUBSCR_DOWNLOAD_MAX_TIME=3', '-e', 'SUBSCR_CONNECT_TIMEOUT=1',
                       '-e', 'GEODATA_AUTO_UPDATE=false',
                       *sum((['-e', f'PROXY_TEST_URL_{site}=http://127.0.0.1:18888/subscription.yaml'] for site in ['YOUTUBE', 'GITHUB', 'TMDB', 'BAIDU']), []), '-e', 'BUILTIN_RULE_FILE=/opt/tests/minimal-template.yaml', IMAGE)
    try:
        portal = 'http://' + docker('port', container, '9090/tcp')
        api = 'http://' + docker('port', container, '9097/tcp')
        authorization = 'Basic ' + base64.b64encode(('admin:' + PASSWORD).encode()).decode()

        def request(path, method='GET', payload=None, auth=True, base=None, bearer=None):
            headers = {'Content-Type': 'application/json'}
            if auth:
                headers['Authorization'] = authorization
            if bearer:
                headers['Authorization'] = 'Bearer ' + bearer
            body = json.dumps(payload).encode() if payload is not None else None
            req = urllib.request.Request((base or portal) + path, body, headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=10) as response:
                    return response.status, response.read()
            except urllib.error.HTTPError as error:
                return error.code, error.read()

        def read(path):
            code, body = request(path + '?t=' + str(time.time()))
            assert code == 200, (path, code, body)
            return json.loads(body)

        def submit(kind, payload):
            task_id = str(uuid.uuid4())
            assert request(f'/requests/{kind}/{task_id}', 'PUT', payload)[0] in (201, 204)
            return task_id

        def result(task_id):
            code, body = request(f'/tasks/{task_id}.json')
            if code != 200:
                return None
            value = json.loads(body)
            return value if 'ok' in value or 'sites' in value or value.get('state') in ('success', 'failed') else None

        def mode(value):
            docker('exec', container, 'python3', '-c', "from pathlib import Path; Path('/tmp/subscription-mode').write_text(" + repr(value) + ")")

        eventually(lambda: request('/')[0] == 200)
        for path in ['/connection.json', '/subscriptions.json', '/settings.json', '/subscription-validate.json', '/requests/updates/test', '/tasks/test.json']:
            assert request(path, auth=False)[0] in (403, 404), path
        public_config = request('/config.js', auth=False)[1].decode()
        assert 'secret' not in public_config.lower()
        secret = read('/connection.json')['secret']
        assert len(secret) >= 32
        assert read('/settings.json')['builtinEnabled'] is False
        assert (data / 'portal.json').stat().st_mode & 0o777 == 0o600
        assert (data / 'Country.mmdb').stat().st_size > 0
        print('PASS: authentication, secret isolation, default settings, offline geodata')

        if os.environ.get('RUN_BROWSER_TESTS') == '1':
            subprocess.run(['node', str(ROOT / 'tests/browser.cjs')], check=True,
                           env={**os.environ, 'PORTAL_URL': portal, 'PORTAL_PASSWORD': PASSWORD, 'BROWSER_SETUP_ONLY': '1'})
        docker('exec', '-d', container, 'python3', '/opt/tests/fixture_server.py')
        url = 'http://127.0.0.1:18888/subscription.yaml'
        valid = submit('validations', {'url': url})
        assert eventually(lambda: result(valid))['ok'] is True
        for suffix in ('uri', 'nodes', 'broken'):
            task = submit('validations', {'url': 'http://127.0.0.1:18888/' + suffix})
            assert eventually(lambda: result(task))['ok'] is False
        initial_id = str(uuid.uuid4())
        assert request('/subscriptions.json', 'PUT', {'requestId': initial_id, 'active': 0, 'urls': [url]})[0] in (201, 204)
        assert eventually(lambda: result(initial_id))['state'] == 'success'
        eventually(lambda: request('/version', base=api, bearer=secret)[0] == 200)
        docker('exec', container, 'bash', '/opt/scripts/healthcheck.sh')
        cache = data / 'proxies' / hashlib.md5(url.encode()).hexdigest()
        original_cache = cache.read_bytes()
        original_config = (data / 'config.yaml').read_bytes()
        print('PASS: real mihomo validation and first startup')
        latency = submit('latency-router', {})
        measured = eventually(lambda: result(latency))
        assert measured['requestId'] == latency and all(site['reachable'] for site in measured['sites'])
        print('PASS: proxy probes obey DIRECT routing rather than an unrelated selected node')

        for value in ('partial', 'broken'):
            mode(value)
            task = submit('updates', {'scope': 'active'})
            assert eventually(lambda: result(task))['state'] == 'failed'
            assert cache.read_bytes() == original_cache
            assert (data / 'config.yaml').read_bytes() == original_config
            docker('exec', container, 'bash', '/opt/scripts/healthcheck.sh')
        mode('valid')
        task = submit('updates', {'scope': 'active'})
        assert eventually(lambda: result(task))['state'] == 'success'
        print('PASS: partial downloads and invalid updates preserve cache; worker recovers')

        # Save a different active subscription during a slow manual update.
        mode('slow')
        pending = submit('updates', {'scope': 'active'})
        eventually(lambda: subprocess.run(['docker', 'exec', container, 'test', '-e', '/tmp/slow-request-started'], stdout=subprocess.DEVNULL).returncode == 0)
        concurrent_id = str(uuid.uuid4())
        alternate = 'http://127.0.0.1:18888/alternate.yaml'
        assert request('/subscriptions.json', 'PUT', {'requestId': concurrent_id, 'active': 1, 'urls': [url, alternate]})[0] in (201, 204)
        assert eventually(lambda: result(pending))['state'] == 'failed'
        assert eventually(lambda: result(concurrent_id))['state'] == 'success'
        assert read('/subscriptions.json')['active'] == 1
        mode('valid')
        back_id = str(uuid.uuid4())
        assert request('/subscriptions.json', 'PUT', {'requestId': back_id, 'active': 0, 'urls': [url]})[0] in (201, 204)
        assert eventually(lambda: result(back_id))['state'] == 'success'
        print('PASS: slow updates preserve concurrent saves and acknowledge the correct request')

        # Force the core reload API to fail, while using the actual update code.
        script = '''source <(sed '/^# ========= 主逻辑/,$d' /entrypoint.sh)
reload_clash_via_api() { return 1; }
update_resources update active simulated-reload-failure
'''
        proc = subprocess.run(['docker', 'exec', container, 'bash', '-c', script], capture_output=True, text=True)
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert cache.read_bytes() == original_cache
        assert (data / 'config.yaml').read_bytes() == original_config
        assert read('/tasks/simulated-reload-failure.json')['state'] == 'failed'
        print('PASS: API reload failure restores the previous config')

        ids = [submit('validations', {'url': url}) for _ in range(2)]
        for task in ids:
            value = eventually(lambda: result(task))
            assert value['requestId'] == task and value['ok'] is True
        switch_id = str(uuid.uuid4())
        assert request('/subscriptions.json', 'PUT', {'requestId': switch_id, 'active': 1, 'urls': [url, 'http://127.0.0.1:18888/broken']})[0] in (201, 204)
        assert eventually(lambda: result(switch_id))['state'] == 'failed'
        eventually(lambda: read('/subscriptions.json')['active'] == 0)
        assert (data / 'config.yaml').read_bytes() == original_config
        print('PASS: queued requests remain independent; failed switch restores selection')

        settings = read('/settings.json')
        settings['requestId'] = str(uuid.uuid4())
        settings['builtinEnabled'] = True
        assert request('/settings.json', 'PUT', settings)[0] in (201, 204)
        assert eventually(lambda: result(settings['requestId']))['state'] == 'success'
        eventually(lambda: '默认代理'.encode() in (data / 'config.yaml').read_bytes())
        settings['requestId'] = str(uuid.uuid4())
        settings['builtinEnabled'] = False
        assert request('/settings.json', 'PUT', settings)[0] in (201, 204)
        assert eventually(lambda: result(settings['requestId']))['state'] == 'success'
        eventually(lambda: (data / 'config.yaml').read_bytes() == original_config)
        time.sleep(3)
        assert result(switch_id)['state'] == 'failed'
        invalid_id = str(uuid.uuid4())
        assert request('/settings.json', 'PUT', {'requestId': invalid_id, 'autoEnabled': True, 'builtinEnabled': False, 'intervalMinutes': -1})[0] in (201, 204)
        assert eventually(lambda: result(invalid_id))['state'] == 'failed'
        assert read('/settings.json')['intervalMinutes'] == 720
        print('PASS: invalid settings rejected; operation results persist')
        print('PASS: template switches apply with the real hot reload API')

        if os.environ.get('RUN_BROWSER_TESTS') == '1':
            subprocess.run(['node', str(ROOT / 'tests/browser.cjs')], check=True,
                           env={**os.environ, 'PORTAL_URL': portal, 'PORTAL_PASSWORD': PASSWORD})
        docker('restart', container)
        portal = 'http://' + docker('port', container, '9090/tcp')
        api = 'http://' + docker('port', container, '9097/tcp')
        eventually(lambda: request('/version', base=api, bearer=secret)[0] == 200)
        assert read('/connection.json')['secret'] == secret
        assert read('/subscriptions.json')['active'] == 0
        assert cache.read_bytes() == original_cache
        docker('exec', container, 'bash', '/opt/scripts/healthcheck.sh')
        print('PASS: restart while subscription server is offline uses last known good cache')
    except Exception:
        print(docker('logs', '--tail', '80', container))
        raise
    finally:
        subprocess.run(['docker', 'exec', container, 'chmod', '-R', 'a+rwX', '/root/.config/clash'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        docker('rm', '-f', container)
