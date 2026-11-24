"""Run against an isolated container with temporary data and a local subscription server."""
import base64
import hashlib
import json
import os
import socket
import struct
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
    legacy_secret = 'legacy-api-key-before-upgrade'
    (data / 'portal.json').write_text(json.dumps({'secret': legacy_secret}))
    container = docker('run', '-d', '--name', 'clash-test-' + uuid.uuid4().hex[:8],
                       '-p', '127.0.0.1::9090', '-e', 'DASH_PORT=19097',
                       '-v', f'{data}:/root/.config/clash', '-v', f'{ROOT / "tests"}:/opt/tests:ro',
                       '-e', f'PORTAL_ADMIN_KEY={PASSWORD}', '-e', 'SUBSCR_RETRY=0',
                       '-e', 'SUBSCR_DOWNLOAD_MAX_TIME=3', '-e', 'SUBSCR_CONNECT_TIMEOUT=1',
                       '-e', 'GEODATA_AUTO_UPDATE=false',
                       *sum((['-e', f'PROXY_TEST_URL_{site}=http://127.0.0.1:18888/subscription.yaml'] for site in ['YOUTUBE', 'GITHUB', 'TMDB', 'BAIDU']), []), '-e', 'BUILTIN_RULE_FILE=/opt/tests/minimal-template.yaml', IMAGE)
    try:
        portal = 'http://' + docker('port', container, '9090/tcp')
        api = portal
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
        setup = json.loads(request('/setup/status.json', auth=False)[1])
        assert setup['state'] == 'pending' and not setup['needsAccount'] and setup['needsSubscription']
        for path in ['/connection.json', '/subscriptions.json', '/settings.json', '/subscription-validate.json', '/requests/updates/test', '/tasks/test.json']:
            assert request(path, auth=False)[0] == request(path)[0] == 403, path
        public_config = request('/config.js', auth=False)[1].decode()
        assert 'secret' not in public_config.lower()
        docker('exec', '-d', container, 'python3', '/opt/tests/fixture_server.py')
        url = 'http://127.0.0.1:18888/subscription.yaml'
        initial_id = str(uuid.uuid4())
        assert request(f'/setup/requests/{initial_id}', 'PUT', {'url': url}, auth=False)[0] == 403
        assert request(f'/setup/requests/{initial_id}', 'PUT', {'url': url})[0] in (201, 204)

        def initial_result():
            code, body = request(f'/setup/results/{initial_id}.json')
            if code == 200:
                value = json.loads(body)
                return value if value['state'] in ('success', 'failed') else None
            return None

        assert eventually(initial_result)['state'] == 'success'
        secret = read('/connection.json')['secret']
        assert len(secret) >= 32
        assert secret != legacy_secret
        assert read('/settings.json')['builtinEnabled'] is False
        assert (data / 'portal.json').stat().st_mode & 0o777 == 0o600
        assert (data / 'Country.mmdb').stat().st_size > 0
        print('PASS: authentication, secret isolation, default settings, offline geodata')

        valid = submit('validations', {'url': url})
        assert eventually(lambda: result(valid))['ok'] is True
        for suffix in ('uri', 'nodes', 'broken'):
            task = submit('validations', {'url': 'http://127.0.0.1:18888/' + suffix})
            assert eventually(lambda: result(task))['ok'] is False
        eventually(lambda: request('/version', base=api, bearer=secret)[0] == 200)
        # Only Portal is published, with a custom internal core port. All API
        # authentication and dashboard assets must work through this one port.
        assert request('/version', auth=False)[0] == 401
        assert request('/version', bearer='wrong-secret')[0] == 401
        assert request('/configs', bearer=legacy_secret)[0] == 401
        assert request('/configs', 'PATCH', {'mode': 'global'}, auth=False)[0] == 401
        assert request('/configs', 'PATCH', {'mode': 'global'}, bearer=legacy_secret)[0] == 401
        docker('exec', container, 'python3', '-c', '''
import socket
with socket.create_connection(('127.0.0.1', 19097), timeout=2):
    pass
address = socket.gethostbyname(socket.gethostname())
with socket.socket() as client:
    client.settimeout(2)
    assert client.connect_ex((address, 19097)) != 0, 'core API listens outside loopback'
''')
        for panel in ('metacubexd', 'zashboard', 'yacd'):
            code, body = request(f'/ui/{panel}/', auth=False)
            assert code == 200 and b'<html' in body.lower(), panel
        assert request('/configs', bearer=secret)[0] == 200
        assert request('/configs', 'PATCH', {'mode': 'rule'}, bearer=secret)[0] == 204
        assert request('/proxies', bearer=secret)[0] == 200

        def websocket(path, read_frame=True):
            target = urllib.parse.urlsplit(portal)
            with socket.create_connection((target.hostname, target.port), timeout=10) as sock:
                sock.settimeout(10)
                nonce = base64.b64encode(os.urandom(16)).decode()
                sock.sendall((f'GET {path}?token={secret} HTTP/1.1\r\nHost: {target.netloc}\r\n'
                              f'Origin: {portal}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                              f'Sec-WebSocket-Key: {nonce}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
                stream = sock.makefile('rb')
                assert b'101' in stream.readline()
                headers = {}
                while (line := stream.readline()) != b'\r\n':
                    key, value = line.decode().split(':', 1)
                    headers[key.lower()] = value.strip()
                expected = base64.b64encode(hashlib.sha1((nonce + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                assert headers['sec-websocket-accept'] == expected
                if read_frame:
                    opcode, length = stream.read(2)
                    assert opcode & 0xf == 1 and length & 0x80 == 0
                    if length == 126:
                        length = struct.unpack('!H', stream.read(2))[0]
                    elif length == 127:
                        length = struct.unpack('!Q', stream.read(8))[0]
                    assert isinstance(json.loads(stream.read(length)), dict)

        for endpoint in ('/traffic', '/connections', '/memory'):
            websocket(endpoint)
        websocket('/logs', read_frame=False)
        print('PASS: only Portal published; dashboard HTML, REST writes, API authentication and WebSocket streams')
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

        def save_proxy_auth(username, password, success=True):
            settings = read('/settings.json')
            settings.update(requestId=str(uuid.uuid4()), proxyUsername=username, proxyPassword=password)
            assert request('/settings.json', 'PUT', settings)[0] in (201, 204)
            assert eventually(lambda: result(settings['requestId']))['state'] == ('success' if success else 'failed')

        def proxy_probe(protocol, credentials=''):
            # Runs entirely inside the test container and reaches the fixture
            # server through the actual HTTP/Mixed/SOCKS listeners.
            port = {'http': 7890, 'mixed': 7893, 'socks': 7891}[protocol]
            scheme = 'socks5h' if protocol == 'socks' else 'http'
            command = ['docker', 'exec', container, 'curl', '-sS', '--max-time', '8', '--noproxy', '',
                       '--proxy', f'{scheme}://127.0.0.1:{port}', '-o', '/dev/null', '-w', '%{http_code}']
            if credentials:
                command += ['--proxy-user', credentials]
            command += ['http://127.0.0.1:18888/subscription.yaml']
            return subprocess.run(command, capture_output=True, text=True)

        save_proxy_auth('', '')
        for protocol in ('http', 'mixed', 'socks'):
            assert proxy_probe(protocol).stdout == '200'
        save_proxy_auth('test-user', '', success=False)
        save_proxy_auth('invalid:user', 'pass', success=False)
        save_proxy_auth('test-user', 'proxy-pass:123')
        for protocol in ('http', 'mixed', 'socks'):
            assert proxy_probe(protocol).stdout != '200'
            assert proxy_probe(protocol, 'test-user:wrong').stdout != '200'
            assert proxy_probe(protocol, 'test-user:proxy-pass:123').stdout == '200'
        # Pause the automatic worker to inject a failed reload deterministically.
        docker('exec', container, 'sh', '-c', 'kill -STOP "$(cat /tmp/portal-auto-worker.pid)"')
        try:
            pending_settings = read('/settings.json')
            pending_settings.update(requestId='proxy-rollback', proxyUsername='replacement', proxyPassword='other-pass')
            assert request('/settings.json', 'PUT', pending_settings)[0] in (201, 204)
            failed_reload = '''source <(sed '/^# ========= 主逻辑/,$d' /entrypoint.sh)
reload_clash_via_api() { return 1; }
update_resources switch switch proxy-rollback
'''
            proc = subprocess.run(['docker', 'exec', container, 'bash', '-c', failed_reload], capture_output=True, text=True)
            assert proc.returncode == 1, proc.stdout + proc.stderr
            assert read('/settings.json')['proxyUsername'] == 'test-user'
            assert result('proxy-rollback')['state'] == 'failed'
            assert proxy_probe('mixed', 'test-user:proxy-pass:123').stdout == '200'
            assert proxy_probe('mixed', 'replacement:other-pass').stdout != '200'
        finally:
            docker('exec', container, 'sh', '-c', 'kill -CONT "$(cat /tmp/portal-auto-worker.pid)"')
        latency = submit('latency-router', {})
        assert all(site['reachable'] for site in eventually(lambda: result(latency))['sites'])
        task = submit('updates', {'scope': 'active'})
        assert eventually(lambda: result(task))['state'] == 'success'
        assert proxy_probe('mixed').stdout == '407'
        assert proxy_probe('mixed', 'test-user:proxy-pass:123').stdout == '200'
        print('PASS: optional proxy authentication, wrong/missing credentials, all proxy listeners and authenticated latency probes')

        if os.environ.get('RUN_BROWSER_TESTS') == '1':
            subprocess.run(['node', str(ROOT / 'tests/browser.cjs')], check=True,
                           env={**os.environ, 'PORTAL_URL': portal, 'PORTAL_PASSWORD': PASSWORD})
        docker('restart', container)
        portal = 'http://' + docker('port', container, '9090/tcp')
        api = portal
        eventually(lambda: request('/version', base=api, bearer=secret)[0] == 200)
        assert read('/connection.json')['secret'] == secret
        assert read('/subscriptions.json')['active'] == 0
        assert cache.read_bytes() == original_cache
        docker('exec', container, 'bash', '/opt/scripts/healthcheck.sh')
        print('PASS: restart while subscription server is offline uses last known good cache')
        docker('exec', '-d', container, 'python3', '/opt/tests/fixture_server.py')
        eventually(lambda: subprocess.run(['docker', 'exec', container, 'curl', '-fsS', '-o', '/dev/null',
                   'http://127.0.0.1:18888/subscription.yaml'], capture_output=True).returncode == 0)
        assert read('/settings.json')['proxyUsername'] == 'test-user'
        assert proxy_probe('mixed').stdout == '407'
        assert proxy_probe('mixed', 'test-user:proxy-pass:123').stdout == '200'
        save_proxy_auth('', '')
        for protocol in ('http', 'mixed', 'socks'):
            assert proxy_probe(protocol).stdout == '200'
        print('PASS: proxy credentials persist after update/restart; clearing both fields disables authentication')
        docker('exec', container, 'bash', '/opt/scripts/healthcheck.sh')
    except Exception:
        print(docker('logs', '--tail', '80', container))
        raise
    finally:
        subprocess.run(['docker', 'exec', container, 'chmod', '-R', 'a+rwX', '/root/.config/clash'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        docker('rm', '-f', container)
