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

    def rotate(self, current, new, confirm=None):
        return tool.change(self.directory, self.auth, {'currentPassword': current, 'newPassword': new,
                           'confirmPassword': new if confirm is None else confirm}, True)

    def snapshot(self):
        return {path.name: path.read_bytes() for path in self.directory.iterdir()}

    def test_custom_password_survives_environment_and_environment_can_reset(self):
        tool.initialize(self.directory, self.auth, 'initial-environment')
        self.rotate('initial-environment', ' 新密码 with spaces ')
        result = tool.initialize(self.directory, self.auth, 'initial-environment')
        self.assertEqual(result, {'password': ' 新密码 with spaces ', 'source': 'custom'})
        self.assertEqual(tool.initialize(self.directory, self.auth, 'reset-environment')['password'], 'reset-environment')

    def test_generated_password_is_distinguished_from_changed_password(self):
        result = tool.initialize(self.directory, self.auth, '')
        self.assertEqual(result['source'], 'generated')
        self.assertEqual(tool.initialize(self.directory, self.auth, '')['password'], result['password'])
        self.rotate(result['password'], '1234')
        self.assertEqual(tool.initialize(self.directory, self.auth, ''), {'password': '1234', 'source': 'custom'})
        self.assertEqual((self.directory / 'portal-admin.key').stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.directory / 'portal-auth.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.auth.stat().st_mode & 0o777, 0o640)

    def test_legacy_saved_password_source_is_migrated(self):
        key = self.directory / 'portal-admin.key'
        key.write_text('f' * 48 + '\n')
        self.assertEqual(tool.initialize(self.directory, self.auth, '')['source'], 'generated')
        (self.directory / 'portal-auth.json').unlink()
        key.write_text('manually-saved-password\n')
        self.assertEqual(tool.initialize(self.directory, self.auth, '')['source'], 'custom')

    def test_invalid_requests_preserve_password_and_credentials(self):
        tool.initialize(self.directory, self.auth, 'current')
        original = self.snapshot()
        for current, new, confirm in [('wrong', 'new', 'new'), ('current', 'new', 'different'),
                                      ('current', '', ''), ('current', 'a\nb', 'a\nb'),
                                      ('current', 'a\0b', 'a\0b'), ('current', 'a' * 129, 'a' * 129)]:
            with self.assertRaises(ValueError):
                self.rotate(current, new, confirm)
            self.assertEqual(self.snapshot(), original)
        with self.assertRaises(ValueError):
            tool.change(self.directory, self.auth, {}, False)
        self.assertEqual(self.snapshot(), original)

    def test_failed_authentication_file_replace_rolls_back_all_files(self):
        tool.initialize(self.directory, self.auth, 'current')
        original = self.snapshot()
        replace = tool.os.replace
        failed = False

        def fail_once(source, target):
            nonlocal failed
            if target == self.auth and not failed:
                failed = True
                raise OSError('simulated replacement failure')
            return replace(source, target)

        with patch.object(tool.os, 'replace', side_effect=fail_once), self.assertRaises(OSError):
            self.rotate('current', 'new')
        self.assertEqual(self.snapshot(), original)


if __name__ == '__main__':
    unittest.main()
