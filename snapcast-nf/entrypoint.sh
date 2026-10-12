#!/bin/sh
set -e

# Persistent volume, mounted at /data: Snapweb in /data/snapweb (the
# config's doc_root), downloads and rqbit's log in /data/snapcast, and the
# torrent list in /data/magnet.txt.
SNAPCAST_DATA_DIR="${SNAPCAST_DATA_DIR:-/data/snapcast}"
SNAPWEB_DATA_DIR="${SNAPWEB_DATA_DIR:-/data/snapweb}"
SNAPSERVER_CONF="${SNAPSERVER_CONF:-/etc/snapserver.conf}"
PLAY_LIST="${PLAY_LIST:-/data/magnet.txt}"
FIFO=/tmp/snapfifo

mkdir -p "$SNAPCAST_DATA_DIR"
chown snapcast:snapcast "$SNAPCAST_DATA_DIR"

# Snapweb lives on the volume so it can be updated without a new image: run
# update-snapweb.sh (copied next to $SNAPWEB_DATA_DIR) from a shell. Seed it
# from the release baked into the image on the first start. nginx serves it
# through the /usr/share/snapweb symlink; it is also snapserver's doc_root.
if [ ! -f "$SNAPWEB_DATA_DIR/index.html" ]; then
  printf "Installing bundled snapweb %s in %s\n" \
    "$(cat /usr/share/snapweb-dist/.version)" "$SNAPWEB_DATA_DIR"
  rm -rf "$SNAPWEB_DATA_DIR"
  mkdir -p "$(dirname "$SNAPWEB_DATA_DIR")"
  cp -a /usr/share/snapweb-dist "$SNAPWEB_DATA_DIR"
fi
# Root owns snapweb; nginx workers and snapserver must be able to read it.
chown -R root:root "$SNAPWEB_DATA_DIR"
chmod a+x "$(dirname "$SNAPWEB_DATA_DIR")"
chmod -R a+rX "$SNAPWEB_DATA_DIR"
ln -sfn "$SNAPWEB_DATA_DIR" /usr/share/snapweb
UPDATE_SNAPWEB="$(dirname "$SNAPWEB_DATA_DIR")/update-snapweb.sh"
cp /usr/local/bin/update-snapweb.sh "$UPDATE_SNAPWEB"
chmod +x "$UPDATE_SNAPWEB"

if [ ! -f "$SNAPSERVER_CONF" ]; then
  printf "SNAPSERVER_CONF %s does not exist\n" "$SNAPSERVER_CONF"
  exit 1
fi
printf "snapserver config: %s\n" "$SNAPSERVER_CONF"

# Create the FIFO before snapserver-rs and play.sh start, so they don't race
# to create it.
rm -f "$FIFO"
mkfifo -m 600 "$FIFO"
chown snapcast:snapcast "$FIFO"

# Cloudflare Tunnel (remotely managed): routes such as tcp://localhost:1704
# or http://localhost:8080 are configured in the Cloudflare dashboard.
# cloudflared only makes outbound connections, so no inbound port is needed.
# If it exits, stop the container: PID 1 becomes snapserver-rs after the
# final exec, so wait for that, then SIGTERM it.
if [ -n "$CLOUDFLARED_TOKEN" ]; then
  printf "Starting cloudflared tunnel\n"
  (
    status=0
    su-exec snapcast cloudflared tunnel --no-autoupdate --loglevel info \
      run --token "$CLOUDFLARED_TOKEN" || status=$?
    printf "cloudflared exited with status %s, stopping container\n" "$status"
    while [ "$(cat /proc/1/comm)" != snapserver-rs ]; do sleep 1; done
    kill -TERM 1
  ) &
else
  printf "CLOUDFLARED_TOKEN not set, skipping cloudflared\n"
fi

# play.sh downloads and plays the torrents in $PLAY_LIST once, then exits;
# snapserver-rs keeps running. setsid: play.sh's Ctrl-C/TERM trap does
# `kill 0` on its process group, which must not include snapserver-rs.
# snapserver-rs starts first: play.sh waits until it is PID 1 (after the
# final exec) and answers JSON-RPC, so the first track's metadata isn't lost.
if [ -f "$PLAY_LIST" ]; then
  (
    while [ "$(cat /proc/1/comm)" != snapserver-rs ] ||
      ! curl -sf --max-time 2 -o /dev/null \
        -d '{"jsonrpc":"2.0","id":1,"method":"Server.GetStatus"}' \
        http://127.0.0.1:1780/jsonrpc; do
      sleep 1
    done
    printf "snapserver-rs is up, starting play.sh with %s\n" "$PLAY_LIST"
    cd "$SNAPCAST_DATA_DIR"
    status=0
    setsid su-exec snapcast /script/play.sh "$PLAY_LIST" || status=$?
    printf "play.sh exited with status %s\n" "$status"
  ) &
else
  printf "%s not found, not playing anything\n" "$PLAY_LIST"
fi

NGINX_CONF="${NGINX_CONF:-/script/nginx.conf}"
printf "Starting nginx with config: %s\n" "$NGINX_CONF"
nginx -c "$NGINX_CONF"

exec su-exec snapcast snapserver-rs --config "$SNAPSERVER_CONF"
