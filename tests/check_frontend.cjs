const fs = require('node:fs');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const html = fs.readFileSync('portal/index.html', 'utf8');
for (const [index, match] of [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].entries()) {
  if (!match[2].trim()) continue;
  if (/type="module"/.test(match[1])) {
    const result = spawnSync(process.execPath, ['--check', '--input-type=module'], {input: match[2], encoding: 'utf8'});
    if (result.status !== 0) throw new Error(result.stderr);
  } else new vm.Script(match[2], {filename: `portal-script-${index}.js`});
}
console.log('Frontend scripts passed syntax checks');

const assert = require('node:assert/strict');
const connectionCode = html.slice(html.indexOf('      const portalPort = window.location.port'), html.indexOf('      const mixedProxyEl ='));
assert.ok(connectionCode.includes('const fillConnectionInfo'));
for (const address of ['http://localhost:9090', 'http://example.com:18080', 'https://portal.example.com', 'https://portal.example.com:8443', 'http://[::1]:18080']) {
  const location = new URL(address);
  const elements = new Map();
  const document = {getElementById(id) {
    if (!elements.has(id)) elements.set(id, {});
    return elements.get(id);
  }};
  vm.runInNewContext(connectionCode + '\nsecret="test-api-key"; fillConnectionInfo();', {
    config: {dashPort: '9097', portalPort: '9090'}, window: {location},
    host: location.hostname, protocol: location.protocol.slice(0, -1), document, URLSearchParams
  });
  const port = location.port || (location.protocol === 'https:' ? '443' : '80');
  assert.equal(elements.get('portal-port').textContent, port);
  assert.doesNotMatch(elements.get('info').innerHTML, /Secret|控制地址|test-api-key/);
  for (const id of ['link-metacubexd', 'link-zashboard', 'link-yacd']) {
    const target = new URL(elements.get(id).href);
    assert.equal(target.origin, location.origin);
    const params = id === 'link-yacd' ? target.searchParams : new URLSearchParams(target.hash.split('?')[1]);
    assert.equal(params.get('port'), port);
    assert.equal(params.get('secret'), 'test-api-key');
    if (id === 'link-yacd') assert.equal(params.get('hostname'), location.origin);
    else {
      assert.equal(params.get('hostname'), location.hostname);
      assert.equal(params.get(location.protocol.slice(0, -1)), 'true');
      assert.equal(params.has(location.protocol === 'https:' ? 'http' : 'https'), false);
    }
  }
}
console.log('PASS: dashboard links follow public HTTP/HTTPS origin and port; homepage hides API credentials');
