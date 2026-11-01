"""Exercise backup settings using synthetic files and a fake uploader."""
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'backup-weechat.sh'


class BackupSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / 'data'
        self.home = self.data / 'custom-weechat'
        self.home.mkdir(parents=True)
        (self.home / 'IRC.CONF').write_text('synthetic config')
        (self.home / 'chat.log').write_text('excluded log')
        (self.home / 'rotated.zst').write_text('rotated log')
        self.settings = self.root / 'settings'
        self.settings.mkdir()
        (self.settings / 'remote').write_text('test-remote:synthetic-destination')
        (self.settings / 'weechat-home').write_text(str(self.home))
        binaries = self.root / 'bin'
        binaries.mkdir()
        uploader = binaries / 'rclone'
        uploader.write_text('#!/bin/sh\nprintf "%s" "$5" > "$TEST_DEST"\ncp "$4" "$TEST_UPLOAD"\n')
        uploader.chmod(0o755)
        # Model the stripped environments of cron and administration shells; no inherited
        # deployment values or personal config files are used by these tests.
        self.env = {'PATH': str(binaries) + ':/usr/bin:/bin',
                    'DATA_DIR': str(self.data), 'BACKUP_SETTINGS_DIR': str(self.settings),
                    'TEST_DEST': str(self.root / 'destination'),
                    'TEST_UPLOAD': str(self.root / 'uploaded.tar.gz')}

    def run_backup(self):
        return subprocess.run([str(SCRIPT)], env=self.env, capture_output=True, text=True)

    def test_clean_environment_reads_settings(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'destination').read_text(), 'test-remote:synthetic-destination')
        with tarfile.open(self.root / 'uploaded.tar.gz') as archive:
            self.assertEqual(archive.getnames(), ['custom-weechat/IRC.CONF'])
        self.assertFalse((self.home / 'rotated.zst').exists())
        self.assertTrue((self.home / 'chat.log').exists())
        self.assertFalse((self.data / 'weechat.tar.gz').exists())
        self.assertNotIn('test-remote', result.stdout + result.stderr)

    def test_explicit_environment_overrides_saved_remote(self):
        self.env['WEECHAT_BACKUP_REMOTE'] = 'override:destination'
        self.assertEqual(self.run_backup().returncode, 0)
        self.assertEqual((self.root / 'destination').read_text(), 'override:destination')

    def test_saved_values_are_literal_not_shell_code(self):
        sentinel = self.root / 'must-not-exist'
        destination = 'remote:folder with spaces; $(touch ' + str(sentinel) + ')'
        (self.settings / 'remote').write_text(destination)
        self.assertEqual(self.run_backup().returncode, 0)
        self.assertEqual((self.root / 'destination').read_text(), destination)
        self.assertFalse(sentinel.exists())

    def test_missing_destination_fails_before_touching_logs(self):
        (self.settings / 'remote').unlink()
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No backup destination configured', result.stderr)
        self.assertTrue((self.home / 'rotated.zst').exists())


if __name__ == '__main__':
    unittest.main()
