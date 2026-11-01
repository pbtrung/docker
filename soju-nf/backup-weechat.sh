#!/bin/sh
# Back up only WeeChat config files and remove compressed rotated logs.
set -eu
umask 077

DATA_DIR="${DATA_DIR:-/data}"
BACKUP_SETTINGS_DIR="${BACKUP_SETTINGS_DIR:-/run/soju-backup}"
# Login shells and cron may have no deployment environment. These files hold
# literal values, never shell code; explicit environment overrides still work.
if [ -z "${WEECHAT_BACKUP_REMOTE:-}" ] && [ -r "$BACKUP_SETTINGS_DIR/remote" ]; then
  WEECHAT_BACKUP_REMOTE="$(cat "$BACKUP_SETTINGS_DIR/remote")"
fi
if [ -z "${WEECHAT_HOME:-}" ] && [ -r "$BACKUP_SETTINGS_DIR/weechat-home" ]; then
  WEECHAT_HOME="$(cat "$BACKUP_SETTINGS_DIR/weechat-home")"
fi
: "${WEECHAT_BACKUP_REMOTE:?No backup destination configured; set WEECHAT_BACKUP_REMOTE on the service and restart}"
WEECHAT_HOME="${WEECHAT_HOME:-$DATA_DIR/weechat}"
archive="$DATA_DIR/weechat.tar.gz"

find "$WEECHAT_HOME" -type f -iname '*.zst' -delete

files="$(mktemp)"
trap 'rm -f "$files"' EXIT
cd "$(dirname "$WEECHAT_HOME")"
find "$(basename "$WEECHAT_HOME")" -type f -iname '*.conf' >"$files"
if [ ! -s "$files" ]; then
  printf "backup-weechat: no config files found in %s\n" "$WEECHAT_HOME" >&2
  exit 1
fi
tar -czf "$archive" -T "$files"

rclone --config "$DATA_DIR/rclone.conf" copy "$archive" "$WEECHAT_BACKUP_REMOTE"
rm -f "$archive"
printf 'backup-weechat: config archive uploaded\n'
