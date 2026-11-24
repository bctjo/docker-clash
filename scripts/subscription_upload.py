#!/usr/bin/env python3
"""Decode a Portal file upload into a private staging file."""
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import sys

MAX_BYTES = 16 * 1024 * 1024


def stage_upload(upload, target):
    if not isinstance(upload, dict):
        raise ValueError('请选择一个 .yaml 或 .yml 文件。')
    name = upload.get('name')
    content = upload.get('content')
    if (not isinstance(name, str) or len(name.encode()) > 255 or not name
            or any(char in '/\\' or ord(char) < 32 or ord(char) == 127 for char in name)
            or not name.lower().endswith(('.yaml', '.yml'))):
        raise ValueError('请选择文件名有效的 .yaml 或 .yml 文件。')
    if not isinstance(content, str) or not 0 < len(content) <= ((MAX_BYTES + 2) // 3) * 4:
        raise ValueError('YAML 文件须为 1 字节至 16 MiB。')
    try:
        body = base64.b64decode(content, validate=True)
        body.decode('utf-8-sig')
    except (ValueError, binascii.Error):
        raise ValueError('无法读取文件，请上传 UTF-8 编码的 YAML。') from None
    if not 0 < len(body) <= MAX_BYTES:
        raise ValueError('YAML 文件须为 1 字节至 16 MiB。')
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())
    return {'url': 'local:' + hashlib.sha256(body).hexdigest(), 'name': name}


def main():
    try:
        request = json.load(sys.stdin)
        print(json.dumps(stage_upload(request.get('upload') if isinstance(request, dict) else None,
                                      Path(sys.argv[1])), ensure_ascii=False))
    except (json.JSONDecodeError, UnicodeError):
        print(json.dumps({'message': '上传请求格式无效。'}, ensure_ascii=False))
        return 1
    except (OSError, ValueError) as error:
        message = str(error) if isinstance(error, ValueError) else '无法暂存 YAML 文件。'
        print(json.dumps({'message': message}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
