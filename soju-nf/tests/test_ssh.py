"""Exercise SSH provisioning with synthetic keys and paths, without Docker."""
import base64
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
KEY = 'ssh-ed25519 ' + base64.b64encode(
    struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + bytes(range(32))
).decode() + ' synthetic-key'


class SSHSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / 'data'
        self.data.mkdir()
        self.host = self.root / 'host'
        self.passwd = self.root / 'passwd'
        self.shadow = self.root / 'shadow'
        self.passwd.write_text('root:x:0:0::/root:/bin/ash\n'
                               f'soju:x:1000:1000::{self.data}:/bin/ash\n'
                               'cloudflared:x:101:101::/nonexistent:/sbin/nologin\n')
        self.shadow.write_text('root:!:0:0:99999:7:::\nsoju:!:0:0:99999:7:::\n')
        self.script = self.root / 'setup-ssh.sh'
        self.script.write_text((ROOT / 'setup-ssh.sh').read_text()
                               .replace('/data', str(self.data))
                               .replace('/etc/tinyssh', str(self.host))
                               .replace('/etc/passwd', str(self.passwd))
                               .replace('/etc/shadow', str(self.shadow)))
        binaries = self.root / 'bin'
        binaries.mkdir()
        # Run the user-side shell as the test user; never touch system accounts.
        for name, body in {
            'su-exec': 'test "$1" = soju || exit 1\nshift\nexec "$@"',
            'tinysshd-makekey': 'mkdir "$1"\nprintf generated > "$1/key"',
        }.items():
            p = binaries / name
            p.write_text('#!/bin/sh\nset -eu\n' + body + '\n')
            p.chmod(0o755)
        self.env = {'PATH': str(binaries) + ':/usr/bin:/bin', 'SSH_PUBLIC_KEY': KEY}

    def launch(self):
        return subprocess.run(['sh', str(self.script)], env=self.env,
                              capture_output=True, text=True)

    def test_key_permissions_rotation_and_host_key_reuse(self):
        self.data.chmod(0o777)
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        ssh = self.data / '.ssh'
        authorized = ssh / 'authorized_keys'
        self.assertEqual(authorized.read_text(), KEY + '\n')
        self.assertEqual(ssh.stat().st_mode & 0o777, 0o700)
        self.assertEqual(authorized.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.data.stat().st_mode & 0o022, 0)
        self.assertEqual(self.host.stat().st_mode & 0o777, 0o700)
        (self.host / 'sshkeydir/key').write_text('existing-host-key')
        self.env['SSH_PUBLIC_KEY'] = KEY.replace('synthetic-key', 'rotated-key')
        self.assertEqual(self.launch().returncode, 0)
        self.assertEqual(authorized.read_text(), self.env['SSH_PUBLIC_KEY'] + '\n')
        self.assertEqual((self.host / 'sshkeydir/key').read_text(), 'existing-host-key')

    def test_reject_missing_malformed_options_and_multiple_keys(self):
        for key in ['', 'ssh-rsa AAAA', 'ssh-ed25519 invalid',
                    'restrict ' + KEY, KEY + '\n' + KEY]:
            with self.subTest(key=key):
                self.env['SSH_PUBLIC_KEY'] = key
                self.assertNotEqual(self.launch().returncode, 0)
                self.assertFalse((self.data / '.ssh').exists())
        self.assertFalse(self.host.exists())

    def test_custom_username_and_restart(self):
        self.env['SSH_USERNAME'] = 'operator'
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'operator:x:1000:1000::{self.data}:/bin/ash\n', self.passwd.read_text())
        self.assertIn('operator:!:', self.shadow.read_text())
        self.assertIn('configured for operator', result.stdout)
        self.assertEqual(self.launch().returncode, 0)
        self.assertEqual(self.passwd.read_text().count('operator:'), 1)

    def test_reject_system_accounts_and_invalid_usernames(self):
        original = self.passwd.read_text()
        for name in ['root', 'cloudflared', '-option', 'bad:name', 'bad\nname', 'User', 'x' * 33]:
            with self.subTest(name=name):
                self.env['SSH_USERNAME'] = name
                self.assertNotEqual(self.launch().returncode, 0)
                self.assertEqual(self.passwd.read_text(), original)
                self.assertFalse((self.data / '.ssh').exists())

    def test_refuse_linked_ssh_directory(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.data / '.ssh').symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.launch().returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_replace_linked_authorized_keys_without_changing_target(self):
        ssh = self.data / '.ssh'
        ssh.mkdir()
        outside = self.root / 'outside'
        outside.write_text('untouched')
        for hardlink in [False, True]:
            with self.subTest(hardlink=hardlink):
                authorized = ssh / 'authorized_keys'
                authorized.unlink(missing_ok=True)
                if hardlink:
                    os.link(outside, authorized)
                else:
                    authorized.symlink_to(outside)
                self.assertEqual(self.launch().returncode, 0)
                self.assertEqual(outside.read_text(), 'untouched')
                self.assertFalse(authorized.is_symlink())
                self.assertEqual(authorized.read_text(), KEY + '\n')


if __name__ == '__main__':
    unittest.main()
