#!/bin/sh
set -e

# Persistent volume, mounted at /data: gamja in /data/gamja.
GAMJA_DATA_DIR="${GAMJA_DATA_DIR:-/data/gamja}"

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
# Only the connector needs the tokens: keep them out of nginx's environment
unset TWINGATE_ACCESS_TOKEN TWINGATE_REFRESH_TOKEN

# nginx is the main process: if it exits, the container stops and Northflank
# restarts it
NGINX_CONF="${NGINX_CONF:-/script/nginx.conf}"
printf "Starting nginx with config: %s\n" "$NGINX_CONF"
exec nginx -c "$NGINX_CONF" -g "daemon off;"
