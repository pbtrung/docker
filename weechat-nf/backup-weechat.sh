#!/bin/sh
# Back up only WeeChat config files and remove compressed rotated logs.
set -eu
umask 077

: "${WEECHAT_BACKUP_REMOTE:?WEECHAT_BACKUP_REMOTE is required (rclone upload destination)}"

DATA_DIR="${DATA_DIR:-/data}"
WEECHAT_HOME="${WEECHAT_HOME:-$DATA_DIR/weechat}"
archive="$DATA_DIR/weechat.tar.gz"

find "$WEECHAT_HOME" -type f -name '*.zst' -delete

files="$(mktemp)"
trap 'rm -f "$files"' EXIT
cd "$WEECHAT_HOME"
find . -type f -name '*.conf' >"$files"
if [ ! -s "$files" ]; then
  printf "backup-weechat: no config files found in %s\n" "$WEECHAT_HOME" >&2
  exit 1
fi
tar -czf "$archive" -T "$files"

rclone --config "$DATA_DIR/rclone.conf" copy "$archive" "$WEECHAT_BACKUP_REMOTE"
rm -f "$archive"
printf "backup-weechat: copied config archive to %s\n" "$WEECHAT_BACKUP_REMOTE"
