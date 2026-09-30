import importlib.util
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('config_tool', ROOT / 'scripts/config_tool.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ConfigTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
