"""Synthetic-only migration, backup, rotation and real-Irssi integration tests."""
import contextlib
import gzip
import importlib.util
import io
import os
from pathlib import Path
import pty
import re
import select
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


converter = module('converter', 'convert-weechat.py')
rotation = module('rotation', 'rotate-irssi-logs.py')


class IrssiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'weechat'
        self.source.mkdir()
        self.target = self.root / 'irssi' / 'config'
        (self.source / 'irc.conf').write_text('''[server_default]
username = "testuser"
realname = "Test User"
nicks = "testnick,testnick_"
tls = on
sasl_mechanism = "plain"
[server]
example.addresses = "irc.example.invalid/6697,backup.example.invalid/6697"
example.autoconnect = on
example.password = "fake-server-password"
example.sasl_username = "testuser"
example.sasl_password = "fake-sasl-password"
example.autojoin = "#test,#locked ,fake-key"
unresolved.addresses = "unresolved.example.invalid/6697"
unresolved.autoconnect = on
unresolved.sasl_password = "${sec.data.fake}"
''')
        # This file must never be accessed by the converter.
        (self.source / 'sec.conf').write_text('not an input')
        with contextlib.redirect_stdout(io.StringIO()):
            converter.convert(self.source, self.target)

    def test_conversion(self):
        text = self.target.read_text()
        for value in ['fake-server-password', 'fake-sasl-password', 'fake-key', 'testnick_', 'CTCPS DCC DCCMSGS']:
            self.assertIn(value, text)
        self.assertNotIn('${sec.', text)
        self.assertEqual(text.count('"autoconnect" = "yes"'), 1)
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            converter.convert(self.source, self.target)
        self.assertEqual(converter.quote('a"b\\c'), '"a\\"b\\\\c"')

    def test_rotation(self):
        logs = self.root / 'logs'
        logs.mkdir()
        active = logs / 'channel.log'
        active.write_text('synthetic message\n')
        now = time.time()
        rotation.rotate(logs, now)
        rotation.rotate(logs, now + 6 * 86400 - 1)
        self.assertEqual(active.read_text(), 'synthetic message\n')
        inode = active.stat().st_ino
        rotation.rotate(logs, now + 6 * 86400)
        self.assertEqual(active.stat().st_ino, inode)
        self.assertEqual(active.read_text(), '')
        archive = logs / 'channel.log.1.gz'
        self.assertEqual(list(logs.glob('*.gz')), [archive])
        self.assertEqual(gzip.decompress(archive.read_bytes()), b'synthetic message\n')
        active.write_text('next period\n')
        rotation.rotate(logs, now + 12 * 86400 - 1)
        self.assertEqual(active.read_text(), 'next period\n')
        rotation.rotate(logs, now + 12 * 86400)
        self.assertEqual(active.read_text(), '')
        self.assertEqual(list(logs.glob('*.gz')), [archive])
        self.assertEqual(gzip.decompress(archive.read_bytes()), b'next period\n')

    def test_backup(self):
        bindir = self.root / 'bin'
        bindir.mkdir()
        fake = bindir / 'rclone'
        fake.write_text('#!/bin/sh\ncp "$4" "$5"\n')
        fake.chmod(0o755)
        (self.target.parent / 'startup').write_text('set max_ctcp_queue 0\n')
        (self.target.parent / 'private.log').write_text('excluded')
        upload = self.root / 'upload.tar.gz'
        env = dict(os.environ, PATH=str(bindir) + ':' + os.environ['PATH'], IRSSI_HOME=str(self.target.parent), IRSSI_BACKUP_REMOTE=str(upload))
        result = subprocess.run([str(ROOT / 'backup-irssi.sh')], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0)
        with tarfile.open(upload) as archive:
            self.assertEqual(set(archive.getnames()), {'irssi', 'irssi/config', 'irssi/startup'})
        fake.write_text('#!/bin/sh\necho fake-sensitive-error >&2\nexit 1\n')
        result = subprocess.run([str(ROOT / 'backup-irssi.sh')], env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b'fake-sensitive-error', result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which('irssi'), 'requires installed irssi')
    def test_installed_irssi(self):
        # This exercises only synthetic config with -! (no connections).
        startup = (ROOT / 'irssi-startup').read_text().replace('/data/irssi/logs', str(self.root / 'logs'))
        (self.target.parent / 'startup').write_text(startup)
        master, slave = pty.openpty()
        env = {'PATH': os.environ['PATH'], 'TERM': 'xterm', 'HOME': str(self.root), 'USER': 'tester', 'LOGNAME': 'tester'}
        proc = subprocess.Popen(['irssi', '--home=' + str(self.target.parent), '--config=' + str(self.target), '--noconnect'], stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        output = bytearray()

        def drain(seconds):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        break
        try:
            drain(1)
            os.write(master, b'/dcc send anyone /tmp/nonexistent\n/ctcp anyone VERSION\n/save\n/quit\n')
            drain(1)
            proc.wait(timeout=5)
            # Never print captured terminal content; it could include config values.
            text = output.decode(errors='replace')
            for failure in ['Unknown setting', 'Error in configuration', 'Error parsing', 'syntax error']:
                if failure in text:
                    clean = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', text)
                    errors = re.findall(r'Unknown settings in configuration file for module.{0,150}', clean)
                    self.fail('Synthetic Irssi config rejected: ' + repr(errors))
            self.assertIn('DCC is disabled', text)
            self.assertIn('CTCP is disabled', text)
            saved = self.target.read_text()
            self.assertIn('max_ctcp_queue = "0"', saved)
            self.assertIn('autolog = "yes"', saved)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)


if __name__ == '__main__':
    unittest.main()
