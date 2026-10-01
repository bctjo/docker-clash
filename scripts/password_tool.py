#!/usr/bin/env python3
"""Persist Portal passwords and atomically replace nginx credentials."""
import argparse
import fcntl
import grp
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile


def read_metadata(directory):
    try:
        value = json.loads((directory / 'portal-auth.json').read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def read_password(directory):
    path = directory / 'portal-admin.key'
    value = path.read_text() if path.exists() else ''
    return value[:-1] if value.endswith('\n') else value


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


def persist(directory, auth_file, password, metadata):
    encoded = password.encode()
    hashed = subprocess.run(['openssl', 'passwd', '-apr1', '-stdin'], input=encoded + b'\n',
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.strip()
    files = [(directory / 'portal-admin.key', encoded + b'\n', False),
             (directory / 'portal-auth.json', json.dumps(metadata).encode() + b'\n', False),
             (auth_file, b'admin:' + hashed + b'\n', True)]
    pending, replaced, previous = [], [], {}
    try:
        for path, content, auth in files:
            previous[path] = path.read_bytes() if path.exists() else None
            pending.append((path, prepare(path, content, auth), auth))
        for path, temporary, auth in pending:
            os.replace(temporary, path)
            replaced.append((path, auth))
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


def initialize(directory, auth_file, environment_password):
    fingerprint = hashlib.sha256(environment_password.encode()).hexdigest()
    metadata = read_metadata(directory)
    saved = read_password(directory)
    if saved and metadata.get('source') == 'custom' and metadata.get('environmentHash') == fingerprint:
        password, source = saved, 'custom'
    elif environment_password:
        password, source = environment_password, 'environment'
    elif saved:
        password = saved
        # Older images generated exactly 48 lowercase hexadecimal characters.
        legacy_generated = not (directory / 'portal-auth.json').exists() and len(saved) == 48 and all(char in '0123456789abcdef' for char in saved)
        source = 'generated' if metadata.get('source') == 'generated' or legacy_generated else 'custom'
    else:
        password, source = secrets.token_hex(24), 'generated'
    persist(directory, auth_file, password, {'source': source, 'environmentHash': fingerprint})
    return {'password': password, 'source': source}


def change(directory, auth_file, payload, enabled):
    if not enabled:
        raise ValueError('Portal 认证已关闭，请先在容器设置中启用认证。')
    if not isinstance(payload, dict):
        raise ValueError('密码请求格式无效。')
    current, new, confirmation = (payload.get(key) for key in ('currentPassword', 'newPassword', 'confirmPassword'))
    if not isinstance(current, str) or not hmac.compare_digest(current.encode(), read_password(directory).encode()):
        raise ValueError('当前密码不正确。')
    if not isinstance(new, str) or not 1 <= len(new) <= 128 or any(char in new for char in '\r\n\0'):
        raise ValueError('新密码须为 1–128 个字符，不能包含换行。')
    if new != confirmation:
        raise ValueError('两次输入的新密码不一致。')
    metadata = read_metadata(directory)
    metadata['source'] = 'custom'
    persist(directory, auth_file, new, metadata)
    return {'ok': True, 'message': '密码已修改并保存。'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['initialize', 'change'])
    parser.add_argument('--directory', type=Path, default=Path('/root/.config/clash'))
    parser.add_argument('--auth-file', type=Path, default=Path('/etc/nginx/.portal_htpasswd'))
    parser.add_argument('--enabled', choices=['true', 'false'], default='true')
    args = parser.parse_args()
    try:
        with (args.directory / '.portal-auth.lock').open('a') as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            if args.command == 'initialize':
                result = initialize(args.directory, args.auth_file, os.environ.get('PORTAL_ADMIN_KEY', ''))
            else:
                result = change(args.directory, args.auth_file, json.load(sys.stdin), args.enabled == 'true')
        print(json.dumps(result, ensure_ascii=False))
    except ValueError as error:
        print(json.dumps({'ok': False, 'message': str(error)}, ensure_ascii=False))
        return 1
    except (OSError, subprocess.SubprocessError):
        print(json.dumps({'ok': False, 'message': '密码保存失败，已保留原密码。'}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
