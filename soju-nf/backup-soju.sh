#!/bin/sh
# Copy a consistent snapshot of the soju DB off the container with rclone.
# Run daily by crond (see entrypoint.sh), or by hand from a shell.
#
# soju keeps writing to main.db and its -wal file while it runs, so copying
# main.db itself could upload a torn or stale file: take a snapshot with
# sqlite3 .backup first, and upload that, still named main.db.
set -eu

SOJU_DATA_DIR="${SOJU_DATA_DIR:-/data/soju}"
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/data/rclone.conf}"
SOJU_BACKUP_REMOTE="${SOJU_BACKUP_REMOTE:-tigris:skypiea/soju/}"

if [ ! -f "$RCLONE_CONFIG_FILE" ]; then
  printf "backup-soju: %s doesn't exist, skipping the backup\n" "$RCLONE_CONFIG_FILE"
  exit 0
fi

tmp="$(mktemp -d)"
# Also removes the snapshot when a step fails
trap 'rm -rf "$tmp"' EXIT

# umask: the snapshot holds password hashes, like main.db
(umask 077 && sqlite3 "$SOJU_DATA_DIR/main.db" ".backup '$tmp/main.db'")
rclone --config "$RCLONE_CONFIG_FILE" copy "$tmp/main.db" "$SOJU_BACKUP_REMOTE"
size="$(wc -c <"$tmp/main.db" | tr -d ' ')"
rm -rf "$tmp"
printf "backup-soju: copied main.db (%s bytes) to %s\n" "$size" "$SOJU_BACKUP_REMOTE"
