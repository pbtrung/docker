#!/bin/sh
set -e

# Persistent Fly volume, mounted at /data: the SQLite DB in /data/soju,
# gamja in /data/gamja and the Cloudflare Mesh registration in
# /data/wgcf-mesh.
SOJU_DATA_DIR="${SOJU_DATA_DIR:-/data/soju}"
GAMJA_DATA_DIR="${GAMJA_DATA_DIR:-/data/gamja}"
WGCF_MESH_DIR="${WGCF_MESH_DIR:-/data/wgcf-mesh}"
WGCF_MESH_ROUTES="${WGCF_MESH_ROUTES:-100.96.0.0/12}"
WG_IF=wg0
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

# Cloudflare Mesh over WireGuard (kernel module, brought up by wg-quick).
# The node is registered once with WGCF_MESH_TOKEN and its config is kept on
# the volume, so restarts and redeploys reuse the same device and Mesh IP
# instead of adding a new one. wg-quick gets a copy of that config:
# - no DNS line, so Fly's resolver stays in place (and no resolvconf run)
# - AllowedIPs = WGCF_MESH_ROUTES instead of ::/0, 0.0.0.0/0: a default
#   route through the tunnel would also take soju's upstream IRC traffic
#   and Fly's private network (fly ssh, logs)
# - MTU capped to fit the link (see below)
# - PostUp pings a Mesh address so the tunnel handshakes right away
wgcf_mesh_conf() {
  ls -t "$WGCF_MESH_DIR"/wgcf-mesh-*.conf 2>/dev/null | head -n 1
}
if [ -n "$WGCF_MESH_TOKEN" ] || [ -n "$(wgcf_mesh_conf)" ]; then
  mkdir -p "$WGCF_MESH_DIR"
  chmod 700 "$WGCF_MESH_DIR"
  if [ -z "$(wgcf_mesh_conf)" ]; then
    printf "Registering Cloudflare Mesh node in %s\n" "$WGCF_MESH_DIR"
    (
      cd "$WGCF_MESH_DIR"
      printf "%s\n" "$WGCF_MESH_TOKEN" |
        wgcf-mesh.sh --name "${WGCF_MESH_NAME:-${FLY_APP_NAME:-soju}}" -
    )
  fi
  conf="$(wgcf_mesh_conf)"
  printf "Starting Cloudflare Mesh with %s\n" "$conf"

  # The generated MTU (1420) assumes a 1500-byte link, but Fly's eth0 is
  # 1420 itself: full-size tunnel packets get dropped, and TCP stalls while
  # small packets (pings, requests) still get through. Cap the MTU at the
  # default route's MTU minus 80 (WireGuard over IPv6, the larger overhead).
  link_dev="$(ip route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
  mtu="$(sed -n 's/^MTU *= *//p' "$conf" | head -n 1)"
  max_mtu=$(($(cat "/sys/class/net/$link_dev/mtu") - 80))
  if [ -z "$mtu" ] || [ "$mtu" -gt "$max_mtu" ]; then
    printf "Lowering the WireGuard MTU from %s to %s (%s MTU minus 80)\n" \
      "${mtu:-none}" "$max_mtu" "$link_dev"
    mtu="$max_mtu"
  fi

  mkdir -p /etc/wireguard
  chmod 700 /etc/wireguard
  (
    umask 077
    sed -e '/^DNS *=/d' \
      -e "s|^AllowedIPs *=.*|AllowedIPs = $(printf "%s" "$WGCF_MESH_ROUTES" | tr ' ' ',' | sed 's/,/, /g')|" \
      -e "s|^MTU *=.*|MTU = $mtu\\
PostUp = ping -c2 -W2 100.96.0.7 \|\| true|" \
      "$conf" >"/etc/wireguard/$WG_IF.conf"
  )
  wg-quick down "$WG_IF" 2>/dev/null || true
  wg-quick up "$WG_IF"
else
  printf "WGCF_MESH_TOKEN not set, skipping Cloudflare Mesh\n"
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
    # Plain IRC: fly.toml exposes nothing, so only Cloudflare Mesh and
    # Fly's private network (6PN) can reach it
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
