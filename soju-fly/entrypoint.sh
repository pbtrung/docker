#!/bin/sh
set -e

# Persistent Fly volume, mounted at /data: the SQLite DB in /data/soju and
# gamja in /data/gamja.
SOJU_DATA_DIR="${SOJU_DATA_DIR:-/data/soju}"
GAMJA_DATA_DIR="${GAMJA_DATA_DIR:-/data/gamja}"
SOJU_CONF=/etc/soju/config

mkdir -p /etc/soju /run/soju "$SOJU_DATA_DIR"

# -R: the DB (and its -wal/-shm files) may have been copied in as root.
# Only soju needs to read it (it holds password hashes and network secrets).
chown -R soju:soju "$SOJU_DATA_DIR"
chmod -R u+rwX,go-rwx "$SOJU_DATA_DIR"
chown soju:soju /run/soju

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
# SOJU_CONFIG_FILE instead if given.
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

# Bootstrap the first admin user on an empty database. soju-rs has no
# sojudb: once soju is up (exec'd below), create the user with sojuctl over
# the admin socket from a background job.
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

# gamja config, served at /config.json.
# Default: always ask for a password, PING every 30s so idle WebSockets
# aren't dropped by NAT or proxies along the way.
printf "%s\n" "${GAMJA_CONFIG_JSON:-{\"server\":{\"auth\":\"mandatory\",\"ping\":30\}\}}" >/tmp/gamja-config.json

# Twingate connector: the only way in from outside. It only makes outbound
# connections, so the app has no public service. Started in a loop that
# restarts it whenever it exits; soju is the main process, so a connector
# crash doesn't take the bouncer down. Its state (API socket, crash reports)
# lives in /run/twingate (TWINGATE_API_ENDPOINT and
# TWINGATE_CRASH_REPORTING_DIR, set in the Dockerfile).
if [ -n "$TWINGATE_NETWORK" ] && [ -n "$TWINGATE_ACCESS_TOKEN" ] && [ -n "$TWINGATE_REFRESH_TOKEN" ]; then
  # Twingate Resources must be IPv4, and <app>.internal only has an IPv6
  # (6PN) address. The connector runs on this machine, so give it a fixed
  # IPv4 of its own on loopback, TWINGATE_RESOURCE_IP: the Resource is that
  # address (no DNS, so it works with browsers' secure DNS), or
  # soju.internal, which resolves to it here (Fly writes /etc/hosts at boot,
  # so add it on every start). 127.0.0.1 can't be the Resource: the client
  # device would answer it itself. nginx listens on 0.0.0.0:8080, and soju's
  # [::]:6667 accepts IPv4 too.
  TWINGATE_RESOURCE_IP="${TWINGATE_RESOURCE_IP:-100.120.10.1}"
  ip addr show dev lo | grep -q " $TWINGATE_RESOURCE_IP/32 " ||
    ip addr add "$TWINGATE_RESOURCE_IP/32" dev lo
  grep -q '[[:space:]]soju\.internal$' /etc/hosts ||
    printf "%s\tsoju.internal\n" "$TWINGATE_RESOURCE_IP" >>/etc/hosts
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

# soju-rs releases before v0.99.7 have no -version: don't let set -e stop
# the container for it
printf "Starting %s\n" "$(soju -version 2>/dev/null || echo "soju-rs (unknown version)")"
exec su-exec soju soju -config "$SOJU_CONF"
