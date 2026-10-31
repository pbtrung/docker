#!/usr/bin/env python3
"""Archive and empty active Irssi logs every six days, keeping one archive."""
import gzip
import os
from pathlib import Path
import shutil
import sys
import time


def rotate(root, now=None):
    os.umask(0o077)
    now = time.time() if now is None else now
    if not root.exists():
        return
    for path in root.rglob('*.log'):
        if path.is_symlink() or not path.is_file():
            continue
        marker = path.with_name(path.name + '.rotation')
        if not marker.exists():
            marker.touch(mode=0o600)
            # Track a fixed period even while Irssi keeps updating the log mtime.
            initial = min(now, path.stat().st_mtime)
            os.utime(marker, (initial, initial))
        if now - marker.stat().st_mtime < 6 * 86400:
            continue
        archive = path.with_name(path.name + '.1.gz')
        temporary = path.with_name(path.name + '.1.gz.tmp')
        try:
            with path.open('rb') as source, gzip.open(temporary, 'wb') as output:
                shutil.copyfileobj(source, output)
            temporary.chmod(0o600)
            # Replace the single archive only after compression succeeds.
            os.replace(temporary, archive)
        finally:
            temporary.unlink(missing_ok=True)
        # Preserve the inode and append handle held by Irssi (copy/truncate).
        with path.open('r+') as output:
            output.truncate(0)
        os.utime(marker, (now, now))


if __name__ == '__main__':
    try:
        rotate(Path('/data/irssi/logs'))
    except Exception:
        print('Irssi log rotation failed; no private paths or data displayed.', file=sys.stderr)
        sys.exit(1)
