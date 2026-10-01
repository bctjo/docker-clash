"""Check optional Portal authentication in isolated containers."""
import base64
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


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()


for label, enabled, custom, saved in [
    ('generated password', True, '', None),
    ('simple custom password', True, '1234', 'saved-password'),
    ('disabled with existing password', False, '1234', 'saved-password'),
    ('disabled on first startup', False, '', None),
]:
    with tempfile.TemporaryDirectory(prefix='clash-auth-') as directory:
        data = Path(directory)
        key = data / 'portal-admin.key'
        if saved:
            key.write_text(saved + '\n')
        container = docker('run', '-d', '--name', 'clash-auth-' + uuid.uuid4().hex[:8],
                           '-p', '127.0.0.1::9090', '-v', f'{data}:/root/.config/clash',
                           '-e', f'PORTAL_AUTH_ENABLED={str(enabled).lower()}',
                           '-e', f'PORTAL_ADMIN_KEY={custom}', '-e', 'GEODATA_AUTO_UPDATE=false', IMAGE)
        try:
            portal = 'http://' + docker('port', container, '9090/tcp')

            def request(path, password=None, payload=None):
                headers = {}
                if password is not None:
                    headers['Authorization'] = 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode()
                body = json.dumps(payload).encode() if payload is not None else None
                req = urllib.request.Request(portal + path, body, headers, method='PUT' if body else 'GET')
                try:
                    with urllib.request.urlopen(req, timeout=5) as response:
                        return response.status, response.read()
                except urllib.error.HTTPError as error:
                    return error.code, error.read()

            deadline = time.monotonic() + 45
            while True:
                try:
                    if request('/config.js')[0] == 200:
                        break
                except (urllib.error.URLError, OSError):
                    pass
                assert time.monotonic() < deadline, docker('logs', '--tail', '20', container)
                time.sleep(0.3)
            config = request('/config.js')[1].decode().split('=', 1)[1].strip().rstrip(';')
            assert json.loads(config)['adminAuthEnabled'] is enabled
            if enabled:
                password = custom or key.read_text().strip()
                assert request('/connection.json')[0] == 403
                assert request('/connection.json', password)[0] == 200
                assert request('/connection.json', 'wrong-password')[0] == 403
            else:
                for path in ['/connection.json', '/settings.json', '/subscriptions.json']:
                    assert request(path)[0] == 200, path
                task = str(uuid.uuid4())
                assert request('/settings.json', payload={'requestId': task, 'autoEnabled': True,
                               'builtinEnabled': False, 'intervalMinutes': 720})[0] in (201, 204)
                while True:
                    code, body = request(f'/tasks/{task}.json')
                    if code == 200 and json.loads(body).get('state') == 'success':
                        break
                    assert time.monotonic() < deadline
                    time.sleep(0.3)
                assert (key.read_text() == saved + '\n') if saved else not key.exists()
                if os.environ.get('RUN_BROWSER_TESTS') == '1' and not saved:
                    subprocess.run(['node', str(ROOT / 'tests/browser.cjs')], check=True,
                                   env={**os.environ, 'PORTAL_URL': portal, 'BROWSER_NO_AUTH': '1', 'BROWSER_SETUP_ONLY': '1'})
            print('PASS:', label, flush=True)
        finally:
            subprocess.run(['docker', 'exec', container, 'chmod', '-R', 'a+rwX', '/root/.config/clash'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            docker('rm', '-f', container)
