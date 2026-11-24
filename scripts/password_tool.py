#!/usr/bin/env python3
"""Manage the persisted Portal environment and nginx credentials."""
import argparse
import fcntl
import grp
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

USERNAME = 'PORTAL_ADMIN_USERNAME'
PASSWORD_HASH = 'PORTAL_ADMIN_PASSWORD_HASH'
ENVIRONMENT_HASH = 'PORTAL_ENVIRONMENT_HASH'
SUBSCRIPTIONS = 'PORTAL_SUBSCRIPTIONS'
SETTINGS = 'PORTAL_SETTINGS'
USERNAME_PATTERN = r'[A-Za-z0-9_.-]{1,32}'
HASH_PATTERN = r'\$6\$[a-f0-9]{16}\$[./A-Za-z0-9]{86}'


def valid_username(value):
    return isinstance(value, str) and re.fullmatch(USERNAME_PATTERN, value)


def valid_password(value):
    return (isinstance(value, str) and 1 <= len(value) <= 128
            and len(value.encode()) <= 256 and not any(char in value for char in '\r\n\0'))


def read_json(path):
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    if not isinstance(value, dict):
        raise ValueError('配置文件格式无效。')
    return value


def read_env(directory):
    path = directory / '.env'
    if not path.exists():
        return {}
    data = {}
    for line in path.read_text().split('\n'):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or key not in (USERNAME, PASSWORD_HASH, ENVIRONMENT_HASH, SUBSCRIPTIONS, SETTINGS):
            raise ValueError('Portal 环境文件格式无效。')
        data[key] = json.loads(value)
    for key in (SUBSCRIPTIONS, SETTINGS):
        if key in data:
            data[key] = json.loads(data[key])
    if bool(data.get(USERNAME)) != bool(data.get(PASSWORD_HASH)) or (data.get(USERNAME) and (
            not valid_username(data[USERNAME]) or not re.fullmatch(HASH_PATTERN, data[PASSWORD_HASH]))):
        raise ValueError('Portal 环境文件中的管理账号无效。')
    return data


def prepare(path, content, auth=False):
    descriptor, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o640 if auth else 0o600)
            if auth:
                os.fchown(stream.fileno(), 0, grp.getgrnam('www-data').gr_gid)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        return Path(name)
    except BaseException:
        Path(name).unlink(missing_ok=True)
        raise


def replace_files(files):
    pending, replaced, previous = [], [], {}
    try:
        for path, content, auth in files:
            previous[path] = path.read_bytes() if path.exists() else None
            pending.append((path, prepare(path, content, auth), auth))
        for path, temporary, auth in pending:
            os.replace(temporary, path)
            replaced.append((path, auth))
        for parent in {path.parent for path, _, _ in files}:
            directory_fd = os.open(parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    except BaseException:
        for path, auth in reversed(replaced):
            if previous[path] is None:
                path.unlink(missing_ok=True)
            else:
                os.replace(prepare(path, previous[path], auth), path)
        raise
    finally:
        for _, temporary, _ in pending:
            temporary.unlink(missing_ok=True)


def env_file(directory, state):
    lines = []
    for key, value in state.items():
        if key in (SUBSCRIPTIONS, SETTINGS):
            value = json.dumps(value, ensure_ascii=True, separators=(',', ':'))
        lines.append(key + '=' + json.dumps(value, ensure_ascii=True))
    content = '# Managed by Clash Portal\n' + '\n'.join(lines) + '\n'
    return directory / '.env', content.encode(), False


def password_hash(password, salt=None):
    return subprocess.run(
        ['openssl', 'passwd', '-6', '-salt', salt or secrets.token_hex(8), '-stdin'],
        input=password.encode() + b'\n', stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    ).stdout.decode().strip()


def auth_entry(path, username, hashed):
    return path, f'{username}:{hashed}\n'.encode(), True


def legacy_password(directory, external_password):
    try:
        saved = (directory / 'portal-admin.key').read_text().removesuffix('\n')
        source = read_json(directory / 'portal-auth.json')
    except FileNotFoundError:
        return ''
    if not valid_password(saved) or source.get('source') == 'generated':
        return ''
    if not source and re.fullmatch(r'[a-f0-9]{48}', saved):
        return ''
    if external_password and (source.get('source') != 'custom' or
                              source.get('environmentHash') != hashlib.sha256(external_password.encode()).hexdigest()):
        return ''
    return saved


def subscription_selection(value):
    if not isinstance(value, dict):
        raise ValueError('订阅配置格式无效。')
    urls = value.get('urls')
    if urls is None:
        urls = [item.get('url') for item in value.get('items', []) if isinstance(item, dict)]
    if not isinstance(urls, list) or any(not isinstance(url, str) for url in urls):
        raise ValueError('订阅配置格式无效。')
    active = value.get('active', 0)
    if type(active) is not int or active < 0 or active >= len(urls):
        active = 0
    selection = {'urls': urls, 'active': active}
    local_names = [{key: item[key] for key in ('url', 'name')}
                   for item in value.get('items', []) if isinstance(item, dict)
                   and item.get('url') in urls and item['url'].startswith('local:')
                   and isinstance(item.get('name'), str)]
    if local_names:
        selection['items'] = local_names
    return selection


def json_file(path, value):
    return path, (json.dumps(value, ensure_ascii=True) + '\n').encode(), False


def restore_settings(directory, state):
    files = []
    if SUBSCRIPTIONS in state:
        path = directory / 'subscriptions.json'
        selection = subscription_selection(state[SUBSCRIPTIONS])
        try:
            cached = read_json(path)
        except ValueError:
            cached = {}
        items = cached.get('items', [])
        merged = {item['url']: item for item in items if isinstance(item, dict) and item.get('url') in selection['urls']}
        for item in selection.get('items', []):
            merged[item['url']] = {**merged.get(item['url'], {}), **item}
        selection['items'] = list(merged.values())
        files.append(json_file(path, selection))
    if SETTINGS in state:
        if not isinstance(state[SETTINGS], dict):
            raise ValueError('Portal 环境文件中的设置无效。')
        files.append(json_file(directory / 'settings.json', state[SETTINGS]))
    return files


def initialize(directory, auth_file, external_username, external_password):
    state = read_env(directory)
    if external_password:
        if not valid_username(external_username) or not valid_password(external_password):
            raise ValueError('容器环境变量中的管理账号或密码格式无效。')
        fingerprint = hashlib.sha256(json.dumps([external_username, external_password]).encode()).hexdigest()
        if state.get(ENVIRONMENT_HASH) != fingerprint or not state.get(USERNAME):
            password = legacy_password(directory, external_password) if not state.get(USERNAME) and external_username == 'admin' else ''
            state.update({USERNAME: external_username, PASSWORD_HASH: password_hash(password or external_password),
                          ENVIRONMENT_HASH: fingerprint})
    elif not state.get(USERNAME):
        password = legacy_password(directory, '')
        if password:
            state.update({USERNAME: 'admin', PASSWORD_HASH: password_hash(password)})
    files = restore_settings(directory, state)
    if state.get(USERNAME):
        files.append(auth_entry(auth_file, state[USERNAME], state[PASSWORD_HASH]))
    replace_files([*files, env_file(directory, state)])
    return {'accountReady': bool(state.get(USERNAME))}


def setup_payload(directory, payload):
    if not isinstance(payload, dict):
        raise ValueError('初始化请求格式无效。')
    state = read_env(directory)
    if not state.get(USERNAME):
        username, password = payload.get('username'), payload.get('password')
        if not valid_username(username):
            raise ValueError('用户名须为 1–32 个字母、数字、点、下划线或短横线。')
        if not valid_password(password):
            raise ValueError('密码须为 1–128 个字符且不超过 256 字节，不能包含换行。')
        if password != payload.get('confirmation'):
            raise ValueError('两次输入的密码不一致。')
    url = payload.get('url', '')
    upload = payload.get('upload')
    if upload is not None and (url or not isinstance(upload, dict)):
        raise ValueError('请选择订阅链接或本地 YAML 文件。')
    if url:
        if (not isinstance(url, str) or len(url.encode()) > 4096
                or any(char.isspace() or ord(char) < 32 or ord(char) == 127 for char in url)):
            raise ValueError('订阅链接格式无效。')
        try:
            parsed = urlsplit(url)
            if parsed.scheme not in ('http', 'https') or not parsed.hostname or not url.startswith(('http://', 'https://')):
                raise ValueError
        except ValueError:
            raise ValueError('请输入以 http:// 或 https:// 开头的完整订阅链接。') from None
    elif not isinstance(url, str):
        raise ValueError('订阅链接格式无效。')
    builtin = payload.get('builtinEnabled')
    if builtin is not None and type(builtin) is not bool:
        raise ValueError('规则模板设置无效。')
    return {'url': url, 'builtin': builtin, 'hasUpload': upload is not None}


def record_state(directory, state, section):
    if section in ('all', 'subscriptions'):
        state[SUBSCRIPTIONS] = subscription_selection(read_json(directory / 'subscriptions.json'))
    if section in ('all', 'settings'):
        settings = read_json(directory / 'settings.json')
        settings.pop('requestId', None)
        state[SETTINGS] = settings


def complete(directory, auth_file, payload):
    setup_payload(directory, payload)
    state = read_env(directory)
    record_state(directory, state, 'all')
    if not state[SUBSCRIPTIONS]['urls']:
        raise ValueError('请先导入并应用有效的订阅。')
    files = []
    if not state.get(USERNAME):
        state.update({USERNAME: payload['username'], PASSWORD_HASH: password_hash(payload['password'])})
        files.append(auth_entry(auth_file, state[USERNAME], state[PASSWORD_HASH]))
    replace_files([*files, env_file(directory, state)])
    return {'ok': True}


def change(directory, auth_file, payload):
    if not isinstance(payload, dict):
        raise ValueError('密码请求格式无效。')
    state = read_env(directory)
    current, new, confirmation = (payload.get(key) for key in ('currentPassword', 'newPassword', 'confirmPassword'))
    hashed = state.get(PASSWORD_HASH, '')
    if not hashed or not valid_password(current) or not hmac.compare_digest(password_hash(current, hashed.split('$')[2]), hashed):
        raise ValueError('当前密码不正确。')
    if not valid_password(new):
        raise ValueError('新密码须为 1–128 个字符且不超过 256 字节，不能包含换行。')
    if new != confirmation:
        raise ValueError('两次输入的新密码不一致。')
    state[PASSWORD_HASH] = password_hash(new)
    replace_files([auth_entry(auth_file, state[USERNAME], state[PASSWORD_HASH]), env_file(directory, state)])
    return {'ok': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['initialize', 'validate-setup', 'complete', 'change', 'sync'])
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--auth-file', type=Path, required=True)
    parser.add_argument('--section', choices=['all', 'subscriptions', 'settings'], default='all')
    args = parser.parse_args()
    try:
        with (args.directory / '.portal-auth.lock').open('a') as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            if args.command == 'initialize':
                result = initialize(args.directory, args.auth_file,
                                    os.environ.get(USERNAME) or 'admin', os.environ.get('PORTAL_ADMIN_KEY', ''))
            elif args.command == 'validate-setup':
                result = setup_payload(args.directory, json.load(sys.stdin))
            elif args.command == 'complete':
                result = complete(args.directory, args.auth_file, json.load(sys.stdin))
            elif args.command == 'change':
                result = change(args.directory, args.auth_file, json.load(sys.stdin))
            else:
                state = read_env(args.directory)
                record_state(args.directory, state, args.section)
                replace_files([env_file(args.directory, state)])
                result = {'ok': True}
        print(json.dumps(result, ensure_ascii=False))
    except (json.JSONDecodeError, UnicodeError):
        print(json.dumps({'ok': False, 'message': '配置数据格式无效。'}, ensure_ascii=False))
        return 1
    except ValueError as error:
        print(json.dumps({'ok': False, 'message': str(error)}, ensure_ascii=False))
        return 1
    except (OSError, subprocess.SubprocessError):
        print(json.dumps({'ok': False, 'message': '无法读写 Portal 配置，请检查数据目录权限。'}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
