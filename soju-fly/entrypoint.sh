#!/bin/sh
set -e

# Persistent Fly volume, mounted at /data: the SQLite DB in /data/soju,
# gamja in /data/gamja and the dnclient enrollment in /data/defined.
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

# Defined Networking (Managed Nebula). dnclient keeps its state in
# DNCLIENT_STATE_DIR (/data/defined, set in the Dockerfile) instead of
# /var/lib/defined, so the host is enrolled once with DN_ENROLLMENT_CODE
# and every later start reuses dnclient.yml: the code isn't used again.
# Enrolling goes through the running daemon's control socket.
DNCLIENT_STATE_DIR="${DNCLIENT_STATE_DIR:-/data/defined}"
DNCLIENT_SOCKET_DIR="${DNCLIENT_SOCKET_DIR:-/run}"
export DNCLIENT_STATE_DIR DNCLIENT_SOCKET_DIR
if [ -n "$DN_ENROLLMENT_CODE" ] || [ -f "$DNCLIENT_STATE_DIR/dnclient.yml" ]; then
  mkdir -p "$DNCLIENT_STATE_DIR"
  chmod 700 "$DNCLIENT_STATE_DIR"
  mkdir -p /dev/net
  if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
  fi

  printf "Starting dnclient with state in %s\n" "$DNCLIENT_STATE_DIR"
  dnclient run -server "${DN_API_SERVER:-https://api.defined.net}" &
  i=0
  while [ ! -S "$DNCLIENT_SOCKET_DIR/dnclient.sock" ]; do
    i=$((i + 1))
    if [ "$i" -gt 10 ]; then
      printf "dnclient didn't open %s/dnclient.sock\n" "$DNCLIENT_SOCKET_DIR"
      exit 1
    fi
    sleep 1
  done

  if [ ! -f "$DNCLIENT_STATE_DIR/dnclient.yml" ]; then
    printf "Enrolling with Defined Networking\n"
    dnclient enroll -code "$DN_ENROLLMENT_CODE"
  else
    printf "Already enrolled with Defined Networking, not enrolling again\n"
  fi
else
  printf "DN_ENROLLMENT_CODE not set, skipping dnclient\n"
fi

# soju config: use SOJU_CONFIG_FILE as-is if given, otherwise render one
# from environment variables.
if [ -n "$SOJU_CONFIG_FILE" ]; then
  if [ ! -f "$SOJU_CONFIG_FILE" ]; then
    printf "SOJU_CONFIG_FILE %s does not exist\n" "$SOJU_CONFIG_FILE"
    exit 1
  fi
  cp "$SOJU_CONFIG_FILE" "$SOJU_CONF"
else
  # Server name shown to clients (gamja: "Connected to soju"). Without it,
  # soju would use the container hostname, i.e. the Fly machine ID.
  SOJU_HOSTNAME="${SOJU_HOSTNAME:-soju}"
  {
    printf "db sqlite3 %s/main.db\n" "$SOJU_DATA_DIR"
    printf "message-store db\n"
    # Plain IRC: fly.toml exposes nothing, so only Defined Networking
    # and Fly's private network (6PN) can reach it
    printf "listen irc+insecure://[::]:6667\n"
    printf "listen http+insecure://127.0.0.1:8081\n"
    printf "listen unix+admin:///run/soju/admin\n"
    # nginx forwards X-Forwarded-For from loopback
    printf "accept-proxy-ip localhost\n"
    printf "hostname %s\n" "$SOJU_HOSTNAME"
    [ -n "$SOJU_TITLE" ] && printf "title %s\n" "$SOJU_TITLE"
    [ -n "$SOJU_EXTRA_CONFIG" ] && printf "%s\n" "$SOJU_EXTRA_CONFIG"
    true
  } >"$SOJU_CONF"
fi
chmod 644 "$SOJU_CONF"
printf "soju config:\n"
sed 's/^/  /' "$SOJU_CONF"

# Bootstrap the first admin user on an empty database.
if [ -n "$SOJU_ADMIN_USER" ] && [ -n "$SOJU_ADMIN_PASSWORD" ] && [ ! -f "$SOJU_DATA_DIR/main.db" ]; then
  printf "Creating admin user %s\n" "$SOJU_ADMIN_USER"
  printf "%s\n" "$SOJU_ADMIN_PASSWORD" |
    su-exec soju sojudb -config "$SOJU_CONF" create-user "$SOJU_ADMIN_USER" -admin
fi

# gamja config, served at /config.json.
# Default: always ask for a password, PING every 30s so idle WebSockets
# aren't dropped by NAT or proxies along the way.
printf "%s\n" "${GAMJA_CONFIG_JSON:-{\"server\":{\"auth\":\"mandatory\",\"ping\":30\}\}}" >/tmp/gamja-config.json

NGINX_CONF="${NGINX_CONF:-/script/nginx.conf}"
printf "Starting nginx with config: %s\n" "$NGINX_CONF"
nginx -c "$NGINX_CONF"

exec su-exec soju soju -config "$SOJU_CONF"
