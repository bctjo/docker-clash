"""Verify real REALITY ClientHellos locally, without subscription credentials.

Run with MIHOMO_BIN=/path/to/mihomo, or in the runtime image (/usr/bin/clash).
The dummy endpoint captures TLS cipher suites, then closes; it is not a working
REALITY server, so a successful end-to-end proxy request is not expected.
"""
import base64
import http.server
import json
import os
from pathlib import Path
import queue
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

import yaml

from test_config_tool import module


MIHOMO = os.environ.get('MIHOMO_BIN', '/usr/bin/clash')


@unittest.skipUnless(Path(MIHOMO).is_file(), 'requires MIHOMO_BIN or the runtime image')
class FingerprintRuntimeTests(unittest.TestCase):
    def test_complete_config_fingerprints_and_provider_refresh(self):
        self.check_fingerprints(None)

    def test_template_fingerprints_and_provider_refresh(self):
        self.check_fingerprints('mode: global\nproxies: []')

    def check_fingerprints(self, template):
        hellos = queue.Queue()

        class Capture(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(2)
                data = b''
                try:
                    while len(data) < 5 or len(data) < 5 + int.from_bytes(data[3:5], 'big'):
                        chunk = self.request.recv(8192)
                        if not chunk:
                            break
                        data += chunk
                except socket.timeout:
                    pass
                hellos.put(data)

        def node(name, **options):
            return {'name': name, 'type': 'vless', 'server': '127.0.0.1',
                    'port': capture.server_address[1],
                    'uuid': '00000000-0000-4000-8000-000000000001',
                    'tls': True, 'servername': 'example.com',
                    'reality-opts': {'public-key': base64.urlsafe_b64encode(b'\x09' + b'\0' * 31).decode().rstrip('=')},
                    **options}

        payload = []

        class Provider(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = yaml.safe_dump({'proxies': payload}).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        with socketserver.ThreadingTCPServer(('127.0.0.1', 0), Capture) as capture, \
                http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider) as provider_server, \
                tempfile.TemporaryDirectory(prefix='clash-fingerprint-') as directory:
            for server in (capture, provider_server):
                threading.Thread(target=server.serve_forever, daemon=True).start()
                self.addCleanup(server.shutdown)
            root = Path(directory)
            with socket.socket() as port_socket:
                port_socket.bind(('127.0.0.1', 0))
                api_port = port_socket.getsockname()[1]
            # Explicit inline nodes establish actual browser signatures using
            # the same core, rather than assuming a particular uTLS version.
            proxies = [node(fp, **{'client-fingerprint': fp}) for fp in ('chrome', 'firefox', 'safari', 'none')]
            proxies += [node('inherited')]
            providers = {}
            for kind in ('http', 'file', 'inline', 'user-expression'):
                nodes = [node(kind + '-default'), node(kind + '-explicit', **{'client-fingerprint': 'firefox'})]
                if kind == 'http':
                    payload[:] = nodes
                    providers[kind] = {'type': kind, 'url': f'http://127.0.0.1:{provider_server.server_port}/nodes', 'interval': 3600}
                elif kind == 'file':
                    (root / 'nodes.yaml').write_text(yaml.safe_dump({'proxies': nodes}))
                    providers[kind] = {'type': kind, 'path': './nodes.yaml'}
                else:
                    providers[kind] = {'type': 'inline', 'payload': nodes}
                if kind == 'user-expression':
                    providers[kind]['override'] = {'override-expr': ['.client-fingerprint = "safari"']}
            source = {'mode': 'global', 'global-client-fingerprint': 'chrome',
                      'proxies': proxies, 'proxy-providers': providers,
                      'profile': {'store-selected': False}, 'log-level': 'debug'}
            config = module.build(yaml.safe_dump(source), template, {
                'external-controller': f'127.0.0.1:{api_port}'}, 'test')
            config = yaml.safe_load(config)
            config.pop('external-ui')  # the runtime image's UI is outside this isolated home
            (root / 'config.yaml').write_text(yaml.safe_dump(config))
            with (root / 'core.log').open('w+') as log:
                process = subprocess.Popen([MIHOMO, '-d', directory], stdout=log, stderr=subprocess.STDOUT)
                try:
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

                    def api(path, method='GET'):
                        request = urllib.request.Request(f'http://127.0.0.1:{api_port}{path}', method=method,
                                                         headers={'Authorization': 'Bearer test'})
                        return opener.open(request, timeout=5)

                    deadline = time.monotonic() + 15
                    while True:
                        try:
                            with api('/providers/proxies/http') as response:
                                if len(json.load(response)['proxies']) == 2:
                                    break
                        except urllib.error.HTTPError as error:
                            error.close()
                        except (OSError, ValueError):
                            pass
                        if process.poll() is not None or time.monotonic() > deadline:
                            log.seek(0)
                            self.fail(log.read())
                        time.sleep(0.1)

                    def cipher_suites(name, provider=None):
                        path = ('/providers/proxies/' + provider + '/' if provider else '/proxies/')
                        path += urllib.parse.quote(name, safe='')
                        path += '/healthcheck' if provider else '/delay'
                        try:
                            with api(path + '?timeout=1500&url=http://example.com'):
                                pass
                        except urllib.error.HTTPError as error:
                            with error:
                                self.assertEqual(error.code, 503)
                        hello = hellos.get(timeout=3)
                        if not hello:
                            return ()
                        self.assertEqual(hello[0], 22, 'expected TLS handshake record')
                        offset = 44 + hello[43]  # record + handshake + version + random + session ID
                        size = int.from_bytes(hello[offset:offset + 2], 'big')
                        suites = [int.from_bytes(hello[i:i + 2], 'big') for i in range(offset + 2, offset + 2 + size, 2)]
                        return tuple(suite for suite in suites if suite & 0x0f0f != 0x0a0a)  # omit GREASE

                    expected = {fp: cipher_suites(fp) for fp in ('chrome', 'firefox', 'safari', 'none')}
                    self.assertEqual(expected['none'], ())
                    self.assertTrue(expected['chrome'])
                    self.assertNotEqual(expected['chrome'], expected['firefox'])
                    self.assertNotEqual(expected['chrome'], expected['safari'])
                    self.assertEqual(cipher_suites('inherited'), expected['chrome'])
                    for kind in providers:
                        for suffix in ('default', 'explicit'):
                            fp = 'safari' if kind == 'user-expression' else 'firefox' if suffix == 'explicit' else 'chrome'
                            with self.subTest(provider=kind, node=suffix):
                                self.assertEqual(cipher_suites(kind + '-' + suffix, kind), expected[fp])
                    payload[:] = [node('http-refreshed')]
                    with api('/providers/proxies/http', method='PUT'):
                        pass
                    self.assertEqual(cipher_suites('http-refreshed', 'http'), expected['chrome'])
                finally:
                    process.terminate()
                    process.wait(timeout=5)
