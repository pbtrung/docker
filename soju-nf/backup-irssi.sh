#!/bin/sh
set -eu
umask 077

# Log maintenance runs separately, even when remote backups are disabled.
if [ -z "${IRSSI_BACKUP_REMOTE:-}" ]; then
  printf 'backup-irssi: IRSSI_BACKUP_REMOTE unset; upload skipped\n'
  exit 0
fi
IRSSI_HOME="${IRSSI_HOME:-/data/irssi}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/data/rclone.conf}"
test -f "$IRSSI_HOME/config"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/irssi"
cp "$IRSSI_HOME/config" "$work/irssi/config"
if [ -f "$IRSSI_HOME/startup" ]; then
  cp "$IRSSI_HOME/startup" "$work/irssi/startup"
fi
tar -czf "$work/irssi.tar.gz" -C "$work" irssi
# Avoid rclone printing remote names, account details or private paths on errors.
if rclone --config "$RCLONE_CONFIG" copy "$work/irssi.tar.gz" "$IRSSI_BACKUP_REMOTE" >"$work/upload.log" 2>&1; then
  printf 'backup-irssi: config archive uploaded\n'
else
  printf 'backup-irssi: upload failed; check rclone configuration privately\n' >&2
  exit 1
fi
