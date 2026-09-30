"""Local subscription server for integration tests; never contacts an airport."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import time

VALID = b'proxies: [{name: Test, type: http, server: 127.0.0.1, port: 10000}]\nproxy-groups: [{name: Proxy, type: select, proxies: [Test, DIRECT]}]\nrules: ["IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "MATCH,Proxy"]\n'
BROKEN = b'proxies: [{name: Test, type: does-not-exist}]\nrules: ["MATCH,Test"]\n'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        mode = Path('/tmp/subscription-mode').read_text().strip() if Path('/tmp/subscription-mode').exists() else 'valid'
        if self.path == '/broken':
            mode = 'broken'
        elif self.path == '/nodes':
            mode = 'nodes'
        elif self.path == '/uri':
            mode = 'uri'
        if mode == 'slow':
            Path('/tmp/slow-request-started').touch()
            time.sleep(2)
            mode = 'valid'
        data = {'valid': VALID, 'broken': BROKEN, 'nodes': VALID.split(b'proxy-groups')[0], 'uri': b'ss://example', 'partial': VALID[:30]}[mode]
        self.send_response(200)
        self.send_header('Content-Length', len(data) + (500 if mode == 'partial' else 0))
        self.send_header('subscription-userinfo', 'upload=1; download=2; total=1000; expire=0')
        self.send_header('profile-title', 'Test subscription')
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def log_message(self, *args):
        pass


ThreadingHTTPServer(('127.0.0.1', 18888), Handler).serve_forever()
