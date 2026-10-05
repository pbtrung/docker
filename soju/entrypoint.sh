#!/bin/sh
set -e

# Persistent volume: SQLite DB + uploads. Mount a Northflank volume here.
DATA_DIR="${DATA_DIR:-/data}"
SOJU_CONF=/etc/soju/config

mkdir -p "$DATA_DIR/uploads" /etc/soju /run/soju
chown soju:soju "$DATA_DIR" "$DATA_DIR/uploads" /run/soju

# soju config: use SOJU_CONFIG_FILE as-is if given (e.g. a Northflank secret
# file), otherwise render one from environment variables.
if [ -n "$SOJU_CONFIG_FILE" ]; then
  if [ ! -f "$SOJU_CONFIG_FILE" ]; then
    printf "SOJU_CONFIG_FILE %s does not exist\n" "$SOJU_CONFIG_FILE"
    exit 1
  fi
  cp "$SOJU_CONFIG_FILE" "$SOJU_CONF"
else
  if [ -z "$SOJU_HTTP_INGRESS" ] && [ -n "$SOJU_HOSTNAME" ]; then
    SOJU_HTTP_INGRESS="https://$SOJU_HOSTNAME"
  fi
  {
    printf "db sqlite3 %s/main.db\n" "$DATA_DIR"
    printf "message-store db\n"
    printf "file-upload fs %s/uploads/\n" "$DATA_DIR"
    printf "listen irc+insecure://0.0.0.0:6667\n"
    printf "listen http+insecure://127.0.0.1:8081\n"
    printf "listen unix+admin:///run/soju/admin.sock\n"
    # nginx forwards X-Forwarded-For from loopback
    printf "accept-proxy-ip localhost\n"
    [ -n "$SOJU_HOSTNAME" ] && printf "hostname %s\n" "$SOJU_HOSTNAME"
    [ -n "$SOJU_HTTP_INGRESS" ] && printf "http-ingress %s\n" "$SOJU_HTTP_INGRESS"
    [ -n "$SOJU_TITLE" ] && printf "title %s\n" "$SOJU_TITLE"
    [ -n "$SOJU_EXTRA_CONFIG" ] && printf "%s\n" "$SOJU_EXTRA_CONFIG"
    true
  } >"$SOJU_CONF"
fi
chmod 644 "$SOJU_CONF"
printf "soju config:\n"
sed 's/^/  /' "$SOJU_CONF"

# Bootstrap the first admin user on an empty database.
if [ -n "$SOJU_ADMIN_USER" ] && [ -n "$SOJU_ADMIN_PASSWORD" ] && [ ! -f "$DATA_DIR/main.db" ]; then
  printf "Creating admin user %s\n" "$SOJU_ADMIN_USER"
  printf "%s\n" "$SOJU_ADMIN_PASSWORD" |
    su-exec soju sojudb -config "$SOJU_CONF" create-user "$SOJU_ADMIN_USER" -admin
fi

# gamja config, served at /config.json.
# Default: always ask for a password, PING every 30s so idle WebSockets
# aren't dropped by the Northflank load balancer.
printf "%s\n" "${GAMJA_CONFIG_JSON:-{\"server\":{\"auth\":\"mandatory\",\"ping\":30\}\}}" >/tmp/gamja-config.json

NGINX_CONF="${NGINX_CONF:-/script/nginx.conf}"
printf "Starting nginx with config: %s\n" "$NGINX_CONF"
nginx -c "$NGINX_CONF"

exec su-exec soju soju -config "$SOJU_CONF"
