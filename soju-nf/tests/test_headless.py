"""Synthetic-only startup checks; never open the deployment's config files."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HeadlessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'weechat'
        self.home.mkdir()
        binaries = self.root / 'bin'
        binaries.mkdir()
        self.capture = self.root / 'capture'
        fake = binaries / 'weechat-headless'
        fake.write_text('#!/usr/bin/python3\nimport json,os,sys\nwith open(os.environ["TEST_CAPTURE"],"w") as f: json.dump({"args":sys.argv[1:],"preload":os.environ.get("LD_PRELOAD")},f)\n')
        fake.chmod(0o755)
        self.env = {'PATH': str(binaries) + ':/usr/bin:/bin', 'HOME': str(self.root),
                    'WEECHAT_HOME': str(self.home), 'WEECHAT_RELAY_PASSWORD': 'synthetic-password',
                    'TEST_CAPTURE': str(self.capture)}

    def launch(self):
        result = subprocess.run([str(ROOT / 'start-weechat.sh')],env=self.env,capture_output=True,text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(self.capture.read_text())

    def test_headless_mimalloc_and_secret_reference(self):
        capture = self.launch()
        self.assertEqual(capture['preload'], '/usr/lib/libmimalloc.so.3')
        self.assertIn('--stdout',capture['args'])
        self.assertIn('--no-script',capture['args'])
        commands = capture['args'][-1]
        self.assertIn('${raw:${env:WEECHAT_RELAY_PASSWORD}}',commands)
        self.assertNotIn('synthetic-password',commands)
        self.assertIn('/set relay.port.api 9001',commands)
        self.assertIn('/set relay.network.bind_address "127.0.0.1"',commands)

    def test_existing_config_still_loads_relay_and_fifo(self):
        (self.home / 'weechat.conf').write_text('# synthetic existing config\n')
        commands = self.launch()['args'][-1]
        self.assertIn('/mute /plugin load relay',commands)
        self.assertIn('/mute /plugin load fifo',commands)
        self.assertIn('/set fifo.file.path',commands)
        self.assertNotIn('/filter add irc_smart',commands)

    @unittest.skipUnless(shutil.which('weechat-headless'), 'requires installed WeeChat')
    def test_native_headless_command_compatibility(self):
        capture = self.launch()
        # Disable the relay listener and autoconnect for this parser/config test.
        args = capture['args']
        args[-1] = args[-1].replace('/set relay.port.api 9001','/set relay.port.api 0') + ';/quit'
        env = {'PATH':'/usr/bin:/bin','HOME':str(self.root),'WEECHAT_RELAY_PASSWORD':'synthetic-password'}
        result = subprocess.run([shutil.which('weechat-headless'),'--no-connect']+args,env=env,capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0)
        combined=result.stdout+result.stderr
        for error in ['unknown option','error setting option','not found: relay','command not found']:
            self.assertNotIn(error,combined.lower())
        relay=(self.home/'relay.conf').read_text()
        self.assertIn('${env:WEECHAT_RELAY_PASSWORD}',relay)
        self.assertNotIn('synthetic-password',relay)


if __name__=='__main__':
    unittest.main()
