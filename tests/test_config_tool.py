import importlib.util
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('config_tool', ROOT / 'scripts/config_tool.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ConfigTests(unittest.TestCase):
    def build_fingerprint_config(self, config, template=None):
        config = {'mode': 'global', **config}
        return yaml.safe_load(module.build(yaml.safe_dump(config), template, {}, 'test'))

    def test_global_fingerprint_migrates_in_both_template_modes(self):
        proxies = [
            {'name': kind, 'type': kind} for kind in module.CLIENT_FINGERPRINT_TYPES
        ] + [
            {'name': 'explicit', 'type': 'vless', 'client-fingerprint': 'firefox'},
            {'name': 'disabled', 'type': 'vless', 'client-fingerprint': 'none'},
            {'name': 'empty', 'type': 'vless', 'client-fingerprint': ''},
            {'name': 'quic', 'type': 'hysteria2'},
            {'name': 'direct', 'type': 'direct'},
        ]
        for template in (None, 'proxies: []\nrules: ["MATCH,DIRECT"]'):
            with self.subTest(template=bool(template)):
                result = self.build_fingerprint_config({
                    'global-client-fingerprint': 'safari', 'proxies': proxies,
                }, template)
                self.assertNotIn('global-client-fingerprint', result)
                nodes = {node['name']: node for node in result['proxies']}
                for kind in module.CLIENT_FINGERPRINT_TYPES:
                    self.assertEqual(nodes[kind]['client-fingerprint'], 'safari')
                for name, value in [('explicit', 'firefox'), ('disabled', 'none'), ('empty', '')]:
                    self.assertEqual(nodes[name]['client-fingerprint'], value)
                for name in ('quic', 'direct'):
                    self.assertNotIn('client-fingerprint', nodes[name])

    def test_absent_or_empty_global_fingerprint_does_not_add_defaults(self):
        for global_setting in ({}, {'global-client-fingerprint': ''}, {'global-client-fingerprint': None}):
            source = {**global_setting, 'proxies': [{'name': 'node', 'type': 'vless'}],
                      'proxy-providers': {'remote': {'type': 'http', 'url': 'https://example.com'}}}
            result = self.build_fingerprint_config(source)
            self.assertNotIn('client-fingerprint', result['proxies'][0])
            self.assertEqual(result['proxy-providers'], source['proxy-providers'])
            self.assertNotIn('global-client-fingerprint', result)

    def test_template_and_subscription_keep_separate_fingerprint_defaults(self):
        template = yaml.safe_dump({'global-client-fingerprint': 'firefox',
                                   'proxies': [{'name': 'template', 'type': 'vmess'}]})
        result = self.build_fingerprint_config({
            'global-client-fingerprint': 'chrome',
            'proxies': [{'name': 'subscription', 'type': 'vless'}],
        }, template)
        self.assertEqual([node['client-fingerprint'] for node in result['proxies']], ['firefox', 'chrome'])
        self.assertNotIn('global-client-fingerprint', result)

    def test_provider_migration_preserves_overrides_and_is_idempotent(self):
        for template in (None, 'proxies: []\nrules: ["MATCH,DIRECT"]'):
            source = {'global-client-fingerprint': 'chrome', 'proxy-providers': {
                kind: {'type': kind, 'override': {'udp': True, 'override-expr': [
                    '.client-fingerprint = "firefox"',
                ]}} for kind in ('http', 'file', 'inline')
            }}
            result = self.build_fingerprint_config(source, template)
            for provider in result['proxy-providers'].values():
                self.assertTrue(provider['override']['udp'])
                expressions = provider['override']['override-expr']
                self.assertEqual(expressions[0], '.client-fingerprint = "firefox"')
                self.assertEqual(len(expressions), 2)
            rebuilt = self.build_fingerprint_config(result, template)
            self.assertEqual(rebuilt['proxy-providers'], result['proxy-providers'])

    def test_malformed_fingerprint_settings_raise_clear_errors(self):
        with self.assertRaisesRegex(ValueError, 'global-client-fingerprint'):
            self.build_fingerprint_config({'global-client-fingerprint': [], 'proxies': [{'type': 'vless'}]})
        for override in ([], {'override-expr': 'not-a-list'}, {'override-expr': [42]}):
            with self.subTest(override=override), self.assertRaisesRegex(ValueError, 'override'):
                self.build_fingerprint_config({'global-client-fingerprint': 'chrome',
                    'proxy-providers': {'bad': {'type': 'http', 'override': override}}})

    def test_complete_config_preserves_rules_and_normalizes_ports(self):
        source = 'proxies: [{name: Proxy, type: http, server: localhost, port: 80}]\nrules: [MATCH,DIRECT]\n# port: 111\nexternal-controller: old\n'
        result = yaml.safe_load(module.build(source, None, {'port': 7890, 'external-controller': '0.0.0.0:9097'}, '密钥"\\&\n'))
        self.assertEqual(result['port'], 7890)
        self.assertEqual(result['external-controller'], '0.0.0.0:9097')
        self.assertEqual(result['secret'], '密钥"\\&\n')
        self.assertEqual(result['proxies'][0]['name'], 'Proxy')

    def test_inline_nodes_are_merged_into_builtin_template(self):
        template = (ROOT / 'config.yaml.template').read_text()
        source = 'proxies: [{name: Test, type: http, server: localhost, port: 80}]'
        result = yaml.safe_load(module.build(source, template, {}, 'test'))
        self.assertEqual(result['proxy-groups'][0]['proxies'][0], '⚡ 自动选择')
        self.assertEqual(result['proxies'][-1]['name'], 'Test')
        self.assertEqual(result['proxy-providers'], {})

    def test_provider_only_subscription_keeps_providers(self):
        template = 'proxies: [{name: 直连, type: direct}]\nproxy-providers: {Airport: {url: old}}\nrules: ["MATCH,直连"]'
        source = 'proxy-providers: {Test: {type: http, url: "https://example.com/nodes.yaml"}}'
        result = yaml.safe_load(module.build(source, template, {}, 'test'))
        self.assertEqual(list(result['proxy-providers']), ['Test'])

    def test_nodes_only_require_template(self):
        with self.assertRaisesRegex(ValueError, '完整 Clash'):
            module.build('proxies: [{name: Test}]', None, {}, '')

    def test_links_and_base64_are_not_advertised_as_usable_configs(self):
        for source in ['ss://example', 'c3M6Ly9leGFtcGxl', '<html>error</html>', '{}']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                module.build(source, None, {}, '')

    def test_invalid_field_types_are_rejected(self):
        with self.assertRaises(ValueError):
            module.build('proxies: bad', None, {}, '')

    def test_proxy_auth_overrides_subscription_and_bypass_prefixes(self):
        source = 'proxies: [{name: Test, type: direct}]\nrules: ["MATCH,Test"]\nauthentication: [old:password]\nskip-auth-prefixes: [127.0.0.0/8]'
        for template in (None, (ROOT / 'tests/minimal-template.yaml').read_text()):
            settings = {'proxyUsername': 'user', 'proxyPassword': '含空格 : password'}
            result = yaml.safe_load(module.build(source, template, {}, 'api-secret', settings))
            self.assertEqual(result['authentication'], ['user:含空格 : password'])
            self.assertEqual(result['skip-auth-prefixes'], [])
            self.assertEqual(result['secret'], 'api-secret')
        result = yaml.safe_load(module.build(source, None, {}, 'api-secret', {'proxyUsername': '', 'proxyPassword': ''}))
        self.assertEqual(result['authentication'], [])
        legacy = yaml.safe_load(module.build(source, None, {}, 'api-secret', {}))
        self.assertEqual(legacy['authentication'], ['old:password'])

    def test_invalid_proxy_credentials_are_rejected(self):
        for username, password in [('user', ''), ('', 'pass'), ('user:name', 'pass'),
                                   ('user', 'p\nass'), ('user', 'p\0ass'), (False, 'pass'),
                                   ('用户' * 100, 'pass')]:
            with self.subTest(username=username), self.assertRaises(ValueError):
                module.proxy_authentication({'proxyUsername': username, 'proxyPassword': password})


if __name__ == '__main__':
    unittest.main()
