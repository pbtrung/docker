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

# Public HTTPS through Cloudflare (nginx-stream.conf, nginx-tls.conf):
# enabled when the Origin CA cert, its key and the Authenticated Origin
# Pulls CA are all set. Each secret may hold the PEM itself or its base64
# encoding.
write_pem() {
  if printf "%s\n" "$1" | grep -q -- "-----BEGIN"; then
    printf "%s\n" "$1" >"$2"
  else
    printf "%s" "$1" | base64 -d >"$2"
  fi
}
rm -rf /etc/nginx/stream.d /etc/nginx/tls.d
mkdir -p /etc/nginx/stream.d /etc/nginx/tls.d
if [ -n "$ORIGIN_CERT" ] && [ -n "$ORIGIN_KEY" ] && [ -n "$CF_AOP_CA" ]; then
  mkdir -p /etc/certs
  chmod 755 /etc/certs
  (umask 077 && write_pem "$ORIGIN_KEY" /etc/certs/origin-key.pem)
  write_pem "$ORIGIN_CERT" /etc/certs/origin.pem
  write_pem "$CF_AOP_CA" /etc/certs/cf-aop-ca.pem
  cp /script/nginx-stream.conf /etc/nginx/stream.d/
  cp /script/nginx-tls.conf /etc/nginx/tls.d/
  printf "Enabling HTTPS on 8443 with the Cloudflare IP filter, origin cert and AOP\n"
else
  printf "ORIGIN_CERT, ORIGIN_KEY or CF_AOP_CA not set, HTTPS on 8443 disabled\n"
fi

NGINX_CONF="${NGINX_CONF:-/script/nginx.conf}"
printf "Starting nginx with config: %s\n" "$NGINX_CONF"
nginx -c "$NGINX_CONF"

# soju-rs releases before v0.99.7 have no -version: don't let set -e stop
# the container for it
printf "Starting %s\n" "$(soju -version 2>/dev/null || echo "soju-rs (unknown version)")"
exec su-exec soju soju -config "$SOJU_CONF"
