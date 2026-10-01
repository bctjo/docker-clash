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
                # The generated key is owned by container root with mode 600.
                # Linux CI users must read it through docker exec, as users do.
                password = custom or docker('exec', container, 'cat', '/root/.config/clash/portal-admin.key')
                assert request('/connection.json')[0] == 403
                assert request('/connection.json', password)[0] == 200
                assert request('/connection.json', 'wrong-password')[0] == 403
                assert request('/requests/password/unauthorized', payload={})[0] == 403
                if not custom:
                    assert f'自动生成密码: {password}' in docker('logs', container)
                else:
                    assert '自动生成密码:' not in docker('logs', container)
                if custom and os.environ.get('RUN_BROWSER_TESTS') == '1':
                    browser_password = '浏览器 新密码 123!'
                    subprocess.run(['node', str(ROOT / 'tests/password_browser.cjs')], check=True,
                                   env={**os.environ, 'PORTAL_URL': portal, 'PORTAL_PASSWORD': password,
                                        'PORTAL_NEW_PASSWORD': browser_password})
                    password = browser_password

                def password_task(payload, old, new):
                    task = str(uuid.uuid4())
                    assert request('/requests/password/' + task, old, payload)[0] in (201, 204)
                    deadline = time.monotonic() + 45
                    while time.monotonic() < deadline:
                        for candidate in (old, new):
                            code, body = request(f'/tasks/{task}.json', candidate)
                            if code == 200 and json.loads(body).get('state') in ('success', 'failed'):
                                return json.loads(body)
                        time.sleep(0.3)
                    raise AssertionError('Password change did not finish')

                new = ' 新密码 with spaces '
                before = request('/connection.json', password)[1]
                for payload in [
                    {'currentPassword': 'wrong', 'newPassword': new, 'confirmPassword': new},
                    {'currentPassword': password, 'newPassword': new, 'confirmPassword': 'different'},
                ]:
                    assert password_task(payload, password, new)['state'] == 'failed'
                    assert request('/connection.json', password)[0] == 200
                payload = {'currentPassword': password, 'newPassword': new, 'confirmPassword': new}
                assert password_task(payload, password, new)['state'] == 'success'
                assert request('/connection.json', password)[0] == 403
                assert request('/connection.json', new)[1] == before
                persisted = subprocess.check_output(['docker', 'exec', container, 'cat', '/root/.config/clash/portal-admin.key'], text=True)
                assert persisted.removesuffix('\n') == new
                docker('restart', container)
                portal = 'http://' + docker('port', container, '9090/tcp')
                deadline = time.monotonic() + 45
                while True:
                    try:
                        if request('/connection.json', new)[0] == 200:
                            break
                    except (urllib.error.URLError, OSError):
                        pass
                    assert time.monotonic() < deadline
                    time.sleep(0.3)
                assert request('/connection.json', password)[0] == 403
                assert new not in docker('logs', container)
                print('PASS: password rotation, unchanged API secret, persistence and custom-password log isolation', flush=True)
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
                task = str(uuid.uuid4())
                assert request('/requests/password/' + task, payload={})[0] in (201, 204)
                while True:
                    code, body = request(f'/tasks/{task}.json')
                    if code == 200 and json.loads(body).get('state') == 'failed':
                        break
                    assert time.monotonic() < deadline
                    time.sleep(0.3)
                assert '自动生成密码:' not in docker('logs', container)
                if os.environ.get('RUN_BROWSER_TESTS') == '1' and not saved:
                    subprocess.run(['node', str(ROOT / 'tests/browser.cjs')], check=True,
                                   env={**os.environ, 'PORTAL_URL': portal, 'BROWSER_NO_AUTH': '1', 'BROWSER_SETUP_ONLY': '1'})
            print('PASS:', label, flush=True)
        finally:
            subprocess.run(['docker', 'exec', container, 'chmod', '-R', 'a+rwX', '/root/.config/clash'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            docker('rm', '-f', container)
