import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('password_tool', Path(__file__).parents[1] / 'scripts/password_tool.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


class PasswordTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.auth = self.directory / '.htpasswd'

    def initialize(self, password='', username='admin'):
        return tool.initialize(self.directory, self.auth, username, password)

    def rotate(self, current, new, confirm=None):
        return tool.change(self.directory, self.auth, {'currentPassword': current, 'newPassword': new,
                           'confirmPassword': new if confirm is None else confirm})

    def snapshot(self):
        return {path.name: path.read_bytes() for path in self.directory.iterdir()}

    def confirm_password(self, password):
        stored = tool.read_env(self.directory)[tool.PASSWORD_HASH]
        self.assertEqual(stored, tool.password_hash(password, stored.split('$')[2]))
        self.assertNotIn(password, (self.directory / '.env').read_text())

    def test_custom_password_survives_unchanged_environment_and_changed_environment_resets(self):
        self.assertTrue(self.initialize('initial-environment', 'operator')['accountReady'])
        self.rotate('initial-environment', ' 新密码 with spaces ')
        self.initialize('initial-environment', 'operator')
        self.confirm_password(' 新密码 with spaces ')
        self.initialize('reset-environment', 'operator')
        self.confirm_password('reset-environment')

    def test_pending_setup_persists_only_after_valid_configuration(self):
        result = self.initialize()
        self.assertFalse(result['accountReady'])
        pending = tool.read_env(self.directory)
        self.assertEqual(pending, {})
        self.assertFalse(self.auth.exists())
        self.initialize()
        self.assertEqual(tool.read_env(self.directory), pending)
        credentials = {'username': 'operator', 'password': 'change-me', 'confirmation': 'change-me'}
        with self.assertRaisesRegex(ValueError, '有效的订阅'):
            tool.complete(self.directory, self.auth, credentials)
        url = "https://example.test/download?q='a'&token=${abc}"
        (self.directory / 'subscriptions.json').write_text(json.dumps({'active': 0, 'urls': [url]}))
        tool.complete(self.directory, self.auth, credentials)
        state = tool.read_env(self.directory)
        self.assertEqual(state[tool.USERNAME], 'operator')
        self.assertEqual(state[tool.SUBSCRIPTIONS], {'active': 0, 'urls': [url]})
        self.confirm_password('change-me')
        self.assertEqual((self.directory / '.env').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.auth.stat().st_mode & 0o777, 0o640)
        (self.directory / 'subscriptions.json').unlink()
        self.assertTrue(self.initialize()['accountReady'])
        self.assertEqual(json.loads((self.directory / 'subscriptions.json').read_text())['urls'], [url])

    def test_legacy_generated_password_requires_setup_and_custom_password_is_migrated(self):
        key = self.directory / 'portal-admin.key'
        key.write_text('f' * 48 + '\n')
        self.assertFalse(self.initialize()['accountReady'])
        key.write_text('manually-saved-password\n')
        self.assertTrue(self.initialize()['accountReady'])
        self.confirm_password('manually-saved-password')

    def test_invalid_requests_preserve_password_and_credentials(self):
        self.initialize('current-password')
        original = self.snapshot()
        for current, new, confirm in [('wrong', 'new', 'new'), ('current-password', 'new', 'different'),
                                      ('current-password', '', ''), ('current-password', 'a\nb', 'a\nb'),
                                      ('current-password', 'a\0b', 'a\0b'), ('current-password', 'a' * 129, 'a' * 129),
                                      ('current-password', '中' * 100, '中' * 100)]:
            with self.assertRaises(ValueError):
                self.rotate(current, new, confirm)
            self.assertEqual(self.snapshot(), original)

    def test_failed_environment_replace_rolls_back_authentication_file(self):
        self.initialize('current-password')
        original = self.snapshot()
        replace = tool.os.replace
        target_env = self.directory / '.env'

        def fail_on_env(source, target):
            if target == target_env:
                raise OSError('simulated replacement failure')
            return replace(source, target)

        with patch.object(tool.os, 'replace', side_effect=fail_on_env), self.assertRaises(OSError):
            self.rotate('current-password', 'new-password')
        self.assertEqual(self.snapshot(), original)


if __name__ == '__main__':
    unittest.main()
