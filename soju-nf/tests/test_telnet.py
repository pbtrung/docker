"""Validate login provisioning against synthetic account files only."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TelnetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.passwd = self.root / 'passwd'
        self.shadow = self.root / 'shadow'
        self.passwd.write_text('root:x:0:0::/root:/bin/ash\nsoju:x:1000:1000::/data:/bin/ash\ntwingate:x:101:101::/run/twingate:/sbin/nologin\n')
        self.shadow.write_text('root:!:0:0:99999:7:::\nsoju:!:0:0:99999:7:::\n')
        self.script = self.root / 'setup-telnet.sh'
        # Redirect all account-file operations into the fixture, never /etc.
        text = (ROOT / 'setup-telnet.sh').read_text().replace('/etc/passwd', str(self.passwd)).replace('/etc/shadow', str(self.shadow))
        self.script.write_text(text)
        self.script.chmod(0o755)
        binaries = self.root / 'bin'
        binaries.mkdir()
        fake = binaries / 'chpasswd'
        fake.write_text('#!/bin/sh\ncat > "$TEST_PASSWORD_INPUT"\nexit "${TEST_PASSWORD_STATUS:-0}"\n')
        fake.chmod(0o755)
        lock = binaries / 'passwd'
        lock.write_text('#!/bin/sh\nprintf "%s\\n" "$2" >> "$TEST_LOCK_INPUT"\n')
        lock.chmod(0o755)
        self.env = {'PATH': str(binaries) + ':/usr/bin:/bin', 'TELNET_USERNAME': 'operator',
                    'TELNET_PASSWORD': 'synthetic:password', 'TEST_PASSWORD_INPUT': str(self.root / 'password-input'),
                    'TEST_LOCK_INPUT': str(self.root / 'locked-accounts')}

    def run_setup(self):
        return subprocess.run([str(self.script)], env=self.env, capture_output=True, text=True)

    def test_custom_nonroot_login_and_restart(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('operator:x:1000:1000::/data:/bin/ash\n', self.passwd.read_text())
        self.assertEqual((self.root / 'password-input').read_text(), 'operator:synthetic:password\n')
        self.assertNotIn('synthetic:password', result.stdout + result.stderr)
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertEqual(self.passwd.read_text().count('operator:'), 1)
        self.env['TELNET_USERNAME'] = 'replacement'
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertIn('operator', (self.root / 'locked-accounts').read_text().splitlines())

    def test_existing_soju_login(self):
        self.env['TELNET_USERNAME'] = 'soju'
        before = self.passwd.read_text()
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertEqual(before, self.passwd.read_text())

    def test_reject_system_accounts_and_invalid_names(self):
        for name in ['root', 'twingate', '-option', 'bad:name', 'bad\nname', 'User', 'x' * 33]:
            with self.subTest(name=name):
                self.env['TELNET_USERNAME'] = name
                self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertFalse((self.root / 'password-input').exists())

    def test_invalid_password_and_update_failure(self):
        self.env['TELNET_PASSWORD'] = 'synthetic\npassword'
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertNotIn('operator:', self.passwd.read_text())
        self.env['TELNET_PASSWORD'] = 'synthetic-password'
        self.env['TEST_PASSWORD_STATUS'] = '1'
        self.assertNotEqual(self.run_setup().returncode, 0)


if __name__ == '__main__':
    unittest.main()
