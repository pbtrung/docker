#!/bin/sh
set -e

# Persistent volume, mounted at /data: the SQLite DB in /data/soju and
# gamja in /data/gamja.
SOJU_DATA_DIR="${SOJU_DATA_DIR:-/data/soju}"
GAMJA_DATA_DIR="${GAMJA_DATA_DIR:-/data/gamja}"
SOJU_CONF=/etc/soju/config

mkdir -p /etc/soju /run/soju "$SOJU_DATA_DIR"

# -R: the DB (and its -wal/-shm files) may have been copied in as root, or
# written by another user. Only soju needs to read it (it holds password
# hashes and network secrets), and soju needs to write the directory too,
# for the -wal and -shm files.
chown -R soju:soju "$SOJU_DATA_DIR"
chmod -R u+rwX,go-rwx "$SOJU_DATA_DIR"
chown soju:soju /run/soju

if [ -f "$SOJU_DATA_DIR/main.db" ]; then
  printf "Using the existing soju database %s\n" "$SOJU_DATA_DIR/main.db"
fi

# gamja lives on the volume so it can be updated without a new image: run
# update-gamja.sh (copied next to $GAMJA_DATA_DIR) from a shell. Seed it from
# the release baked into the image on the first start; nginx serves it
# through the /usr/share/gamja symlink.
if [ ! -f "$GAMJA_DATA_DIR/index.html" ]; then
  printf "Installing bundled gamja %s in %s\n" \
    "$(cat /usr/share/gamja-dist/.version)" "$GAMJA_DATA_DIR"
  rm -rf "$GAMJA_DATA_DIR"
  mkdir -p "$(dirname "$GAMJA_DATA_DIR")"
  cp -a /usr/share/gamja-dist "$GAMJA_DATA_DIR"
fi
# Root owns gamja; nginx workers must be able to reach and read it.
chown -R root:root "$GAMJA_DATA_DIR"
chmod a+x "$(dirname "$GAMJA_DATA_DIR")"
chmod -R a+rX "$GAMJA_DATA_DIR"
ln -sfn "$GAMJA_DATA_DIR" /usr/share/gamja
UPDATE_GAMJA="$(dirname "$GAMJA_DATA_DIR")/update-gamja.sh"
cp /usr/local/bin/update-gamja.sh "$UPDATE_GAMJA"
chmod +x "$UPDATE_GAMJA"

# soju config: soju.conf is baked into the image as $SOJU_CONF. Use
# SOJU_CONFIG_FILE instead if given (e.g. a Northflank secret file).
if [ -n "$SOJU_CONFIG_FILE" ]; then
  if [ ! -f "$SOJU_CONFIG_FILE" ]; then
    printf "SOJU_CONFIG_FILE %s does not exist\n" "$SOJU_CONFIG_FILE"
    exit 1
  fi
  cp "$SOJU_CONFIG_FILE" "$SOJU_CONF"
fi
chmod 644 "$SOJU_CONF"
printf "soju config:\n"
sed 's/^/  /' "$SOJU_CONF"

# Bootstrap the first admin user on an empty database only: an existing
# main.db keeps its users. soju-rs has no sojudb: once soju is up (exec'd
# below), create the user with sojuctl over the admin socket from a
# background job.
if [ -n "$SOJU_ADMIN_USER" ] && [ -n "$SOJU_ADMIN_PASSWORD" ] && [ ! -f "$SOJU_DATA_DIR/main.db" ]; then
  (
    i=0
    while [ ! -S /run/soju/admin ]; do
      i=$((i + 1))
      if [ "$i" -gt 30 ]; then
        printf "soju didn't open /run/soju/admin, admin user not created\n"
        exit 1
      fi
      sleep 1
    done
    printf "Creating admin user %s\n" "$SOJU_ADMIN_USER"
    su-exec soju sojuctl -config "$SOJU_CONF" user create \
      -username "$SOJU_ADMIN_USER" -password "$SOJU_ADMIN_PASSWORD" -admin
  ) &
fi

# Daily DB backup with rclone (backup-soju.sh), run by BusyBox crond as
# root. rclone.conf holds the storage credentials: root only. crond runs in
# the foreground, as a background job, so it and its jobs keep the
# container's stdout and stderr (-d 8: log the jobs it starts to stderr).
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/data/rclone.conf}"
if [ -f "$RCLONE_CONFIG_FILE" ]; then
  chown root:root "$RCLONE_CONFIG_FILE"
  chmod 600 "$RCLONE_CONFIG_FILE"
fi
SOJU_BACKUP_CRON="${SOJU_BACKUP_CRON:-0 3 * * *}"
printf "%s /usr/local/bin/backup-soju.sh\n" "$SOJU_BACKUP_CRON" >/etc/crontabs/root
printf "Scheduling the soju DB backup: %s\n" "$SOJU_BACKUP_CRON"
crond -f -d 8 &

# gamja config, served at /config.json.
# Default: always ask for a password, PING every 30s so idle WebSockets
# aren't dropped by NAT or proxies along the way.
printf "%s\n" "${GAMJA_CONFIG_JSON:-{\"server\":{\"auth\":\"mandatory\",\"ping\":30\}\}}" >/tmp/gamja-config.json

# Twingate connector: the only way in from outside. It only makes outbound
# connections, so no port needs to be public. Started in a loop that
# restarts it whenever it exits. Its state (API socket, crash reports)
# lives in /run/twingate (TWINGATE_API_ENDPOINT and
# TWINGATE_CRASH_REPORTING_DIR, set in the Dockerfile).
if [ -n "$TWINGATE_NETWORK" ] && [ -n "$TWINGATE_ACCESS_TOKEN" ] && [ -n "$TWINGATE_REFRESH_TOKEN" ]; then
  # The Twingate Resource is a name, TWINGATE_RESOURCE_HOST, that resolves
  # to this container's own IPv4 address here. The address changes with
  # every restart and the container can't add a fixed one (no NET_ADMIN on
  # Northflank), so map the name in /etc/hosts on every start. nginx listens
  # on all addresses.
  TWINGATE_RESOURCE_HOST="${TWINGATE_RESOURCE_HOST:-soju.internal}"
  pod_ip="$(ip -4 route get 1.1.1.1 2>/dev/null |
    sed -n 's/.* src \([0-9.]*\).*/\1/p')"
  if [ -n "$pod_ip" ] &&
    { grep -v "[[:space:]]$TWINGATE_RESOURCE_HOST\$" /etc/hosts
      printf "%s\t%s\n" "$pod_ip" "$TWINGATE_RESOURCE_HOST"; } >/tmp/hosts &&
    cat /tmp/hosts >/etc/hosts; then
    printf "Twingate Resource %s is %s\n" "$TWINGATE_RESOURCE_HOST" "$pod_ip"
  else
    printf "Can't map %s in /etc/hosts, the Twingate Resource won't resolve\n" \
      "$TWINGATE_RESOURCE_HOST"
  fi
  rm -f /tmp/hosts

  mkdir -p /run/twingate
  chown twingate:twingate /run/twingate
  chmod 700 /run/twingate
  printf "Starting the Twingate connector for network %s\n" "$TWINGATE_NETWORK"
  (
    while :; do
      su-exec twingate /opt/twingate/connectord || true
      printf "Twingate connector exited, restarting in 5 s\n"
      sleep 5
    done
  ) &
else
  printf "TWINGATE_NETWORK, TWINGATE_ACCESS_TOKEN or TWINGATE_REFRESH_TOKEN not set, Twingate connector disabled\n"
fi
# Only the connector needs the tokens: keep them out of nginx's and soju's
# environment
unset TWINGATE_ACCESS_TOKEN TWINGATE_REFRESH_TOKEN

NGINX_CONF="${NGINX_CONF:-/script/nginx.conf}"
printf "Starting nginx with config: %s\n" "$NGINX_CONF"
nginx -c "$NGINX_CONF"

# soju is the main process: if it exits, the container stops and Northflank
# restarts it. soju-rs releases before v0.99.7 have no -version: don't let
# set -e stop the container for it.
printf "Starting %s\n" "$(soju -version 2>/dev/null || echo "soju-rs (unknown version)")"
exec su-exec soju soju -config "$SOJU_CONF"
