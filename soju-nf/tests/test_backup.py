"""Verify live SQLite snapshots with a synthetic database and local uploader."""
from pathlib import Path
import os
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'backup-soju.sh'


@unittest.skipUnless(shutil.which('sqlite3'), 'requires sqlite3 CLI')
class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / 'database'
        self.data.mkdir()
        self.db = sqlite3.connect(self.data / 'main.db')
        self.addCleanup(self.db.close)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('CREATE TABLE messages (body TEXT)')
        self.db.execute("INSERT INTO messages VALUES ('committed in WAL')")
        self.db.commit()
        settings = self.root / 'settings'
        settings.mkdir()
        (settings / 'data-dir').write_text(str(self.data))
        (settings / 'remote').write_text('test:destination')
        config = self.root / 'rclone.conf'
        config.write_text('synthetic config')
        (settings / 'rclone-config').write_text(str(config))
        binaries = self.root / 'bin'
        binaries.mkdir()
        uploader = binaries / 'rclone'
        uploader.write_text('#!/bin/sh\nset -eu\n'
                            'printf "%s" "$5" > "$TEST_DEST"\n'
                            'printf "%s" "$4" > "$TEST_SNAPSHOT"\n'
                            '[ "${TEST_FAIL:-0}" = 0 ] || exit 7\n'
                            'cp "$4" "$TEST_UPLOAD"\n')
        uploader.chmod(0o755)
        self.env = {'PATH': str(binaries) + ':/usr/bin:/bin',
                    'BACKUP_SETTINGS_DIR': str(settings),
                    'TEST_DEST': str(self.root / 'destination'),
                    'TEST_SNAPSHOT': str(self.root / 'snapshot-path'),
                    'TEST_UPLOAD': str(self.root / 'uploaded.db')}

    def launch(self):
        return subprocess.run([str(SCRIPT)], env=self.env, capture_output=True, text=True)

    def test_snapshot_contains_committed_wal_and_is_removed(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        with sqlite3.connect(self.root / 'uploaded.db') as snapshot:
            self.assertEqual(snapshot.execute('SELECT body FROM messages').fetchall(),
                             [('committed in WAL',)])
            self.assertEqual(snapshot.execute('PRAGMA integrity_check').fetchone(), ('ok',))
        self.assertFalse(Path((self.root / 'snapshot-path').read_text()).exists())
        self.assertEqual((self.root / 'destination').read_text(), 'test:destination')

    def test_explicit_remote_is_literal(self):
        marker = self.root / 'must-not-exist'
        remote = 'remote:spaces; $(touch ' + str(marker) + ")'"
        self.env['SOJU_BACKUP_REMOTE'] = remote
        self.assertEqual(self.launch().returncode, 0)
        self.assertEqual((self.root / 'destination').read_text(), remote)
        self.assertFalse(marker.exists())

    def test_upload_failure_removes_snapshot(self):
        self.env['TEST_FAIL'] = '1'
        self.assertEqual(self.launch().returncode, 7)
        self.assertFalse(Path((self.root / 'snapshot-path').read_text()).exists())
        self.assertTrue((self.data / 'main.db').exists())

    def test_missing_remote_fails_without_upload(self):
        (self.root / 'settings/remote').unlink()
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No backup destination configured', result.stderr)
        self.assertFalse((self.root / 'destination').exists())

    def test_missing_database_does_not_create_empty_backup(self):
        self.env['SOJU_DATA_DIR'] = str(self.root / 'missing')
        self.assertNotEqual(self.launch().returncode, 0)
        self.assertFalse((self.root / 'missing').exists())
        self.assertFalse((self.root / 'destination').exists())


if __name__ == '__main__':
    unittest.main()
