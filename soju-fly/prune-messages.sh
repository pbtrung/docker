#!/bin/sh
# Delete messages older than a number of days from the soju DB, in every
# network and channel/query, then VACUUM the DB to give the space back.
# Usage: prune-messages.sh <main.db> <days>
#        prune-messages.sh /data/soju/main.db 20
set -e

if [ "$#" -ne 2 ]; then
  printf "Usage: %s <main.db> <days>\n" "$0" >&2
  exit 1
fi
DB="$1"
DAYS="$2"

if [ ! -f "$DB" ]; then
  printf "%s does not exist\n" "$DB" >&2
  exit 1
fi
case "$DAYS" in
  '' | *[!0-9]*)
    printf "days must be a whole number, not %s\n" "$DAYS" >&2
    exit 1
    ;;
esac

# Run sqlite3 as the DB's owner: run as root, it would leave root-owned
# -wal/-shm files behind that soju can't open.
owner="$(stat -c %u "$DB")"
if [ "$(id -u)" = 0 ] && [ "$owner" != 0 ]; then
  run() { su-exec "$owner" "$@"; }
else
  run() { "$@"; }
fi

size() { du -h "$DB" | cut -f1; }

# soju stores Message.time as UTC text ("%Y-%m-%dT%H:%M:%fZ"), so the
# cutoff in the same format compares as a string. The MessageFTSDelete
# trigger removes the deleted messages from the search index too.
# soju may be running: wait for its locks instead of failing.
cutoff="strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-$DAYS days')"
printf "%s: %s, deleting messages older than %s days\n" "$DB" "$(size)" "$DAYS"
run sqlite3 "$DB" <<EOF
.timeout 30000
SELECT 'Cutoff: ' || $cutoff;
SELECT 'Messages: ' || count(*) FROM Message;
DELETE FROM Message WHERE time < $cutoff;
SELECT 'Deleted: ' || changes();
INSERT INTO MessageFTS(MessageFTS) VALUES ('optimize');
EOF

printf "Vacuuming %s\n" "$DB"
run sqlite3 "$DB" <<EOF
.timeout 30000
VACUUM;
PRAGMA wal_checkpoint(TRUNCATE);
EOF
printf "%s: %s\n" "$DB" "$(size)"
