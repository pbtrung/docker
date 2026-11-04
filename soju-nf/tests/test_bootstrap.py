"""Exercise the entrypoint's admin bootstrap using a synthetic admin socket CLI."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'entrypoint.sh'


class BootstrapTests(unittest.TestCase):
    def launch(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'sojuctl'
            fake.write_text('''#!/bin/sh
if [ "$2" = status ]; then
  case "$TEST_MODE" in
    existing) printf 'admin (admin, enabled)\\n' ;;
    missing) printf 'unknown username admin\\n' >&2; exit 1 ;;
    regular) printf 'admin (enabled)\\n' ;;
    error) printf 'connection refused\\n' >&2; exit 1 ;;
  esac
else
  printf '%s\\n' "$@" > "$TEST_CREATED"
fi
''')
            fake.chmod(0o755)
            source = SCRIPT.read_text()
            start = source.index('# Check the account on every start')
            end = source.index('unset admin_password', start)
            script = '''set -e
run_soju() { "$@"; }
admin_user=admin
admin_password=synthetic-password
''' + source[start:end]
            created = root / 'created'
            result = subprocess.run(['sh', '-c', script], capture_output=True, text=True,
                                    env={'PATH': str(root) + ':/usr/bin:/bin',
                                         'TEST_MODE': mode, 'TEST_CREATED': str(created)})
            return result, created.read_text() if created.exists() else None

    def test_create_only_unknown_user(self):
        result, created = self.launch('missing')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(created.splitlines(), ['user', 'create', '-username', 'admin',
                                              '-password', 'synthetic-password', '-admin'])

    def test_existing_admin_preserves_password(self):
        result, created = self.launch('existing')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(created)

    def test_regular_user_and_transport_errors_fail(self):
        for mode in ['regular', 'error']:
            with self.subTest(mode=mode):
                result, created = self.launch(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(created)


if __name__ == '__main__':
    unittest.main()
