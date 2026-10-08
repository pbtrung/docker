#!/bin/sh
set -e

# Persistent volume: WeeChat config, logs, scripts. Mount a Northflank
# volume here.
DATA_DIR="${DATA_DIR:-/data}"
export WEECHAT_HOME="${WEECHAT_HOME:-$DATA_DIR/weechat}"

# The relay refuses every client without a password, so don't start without
# one.
if [ -z "$WEECHAT_RELAY_PASSWORD" ]; then
  printf "WEECHAT_RELAY_PASSWORD is not set\n"
  exit 1
fi

mkdir -p "$WEECHAT_HOME"
chown weechat:weechat "$DATA_DIR" "$WEECHAT_HOME"

# Glowing Bear lives on the volume so it can be updated without a new image:
# run $DATA_DIR/update-glowing-bear.sh from a shell. Seed it from the release
# baked into the image on the first start; nginx serves it through the
# /usr/share/glowing-bear symlink.
GLOWING_BEAR_DIR="$DATA_DIR/glowing-bear"
if [ ! -f "$GLOWING_BEAR_DIR/index.html" ]; then
  printf "Installing bundled Glowing Bear %s in %s\n" \
    "$(cat /usr/share/glowing-bear-dist/.version)" "$GLOWING_BEAR_DIR"
  rm -rf "$GLOWING_BEAR_DIR"
  cp -a /usr/share/glowing-bear-dist "$GLOWING_BEAR_DIR"
fi
ln -sfn "$GLOWING_BEAR_DIR" /usr/share/glowing-bear
cp /usr/local/bin/update-glowing-bear.sh "$DATA_DIR/update-glowing-bear.sh"
chmod +x "$DATA_DIR/update-glowing-bear.sh"

# WeeChat commands run after startup (-r). They are evaluated, so the
# ${raw:...} wrappers store the ${env:...} references in relay.conf instead of
# the secrets themselves: WeeChat reads them from the environment whenever a
# relay client authenticates.
CMDS=""
add_cmd() {
  CMDS="${CMDS:+$CMDS;}$1"
}

# Sensible defaults, only on the very first start (no weechat.conf yet), so
# that later changes made from Glowing Bear are kept.
if [ ! -f "$WEECHAT_HOME/weechat.conf" ]; then
  printf "First start, applying default WeeChat settings\n"
  # logs: rotate at 10 MB, compress rotated files with zstd
  add_cmd '/set logger.file.rotation_size_max "10m"'
  add_cmd '/set logger.file.rotation_compression_type zstd'
  add_cmd '/set logger.file.rotation_compression_level 50'
  # hide join/part/quit of people who haven't spoken recently
  add_cmd '/set irc.look.smart_filter on'
  add_cmd '/filter add irc_smart * irc_smart_filter *'
  # remember joined/parted channels in the server autojoin list
  add_cmd '/set irc.server_default.autojoin_dynamic on'
  # don't pop up the relay list buffer whenever a client connects
  add_cmd '/set relay.look.auto_open_buffer off'
  # Privacy hardening, from
  # https://gist.github.com/atoponce/f19666d6b206a10b411b97381a1861a1
  # DCC (also can't work behind the Northflank load balancer)
  add_cmd '/set weechat.plugin.autoload "*,!xfer"'
  add_cmd '/plugin unload xfer'
  # don't answer CTCP requests (they leak client version, time zone, ...)
  for ctcp in action clientinfo finger ping source time userinfo version; do
    add_cmd "/set irc.ctcp.$ctcp \"\""
  done
  # no "WeeChat <version>" part/quit messages (renamed from
  # default_msg_part/default_msg_quit in WeeChat 4.x)
  add_cmd '/set irc.server_default.msg_part ""'
  add_cmd '/set irc.server_default.msg_quit ""'
  # stable FIFO path for weechat-cmd (default includes the PID)
  # shellcheck disable=SC2016 # ${...} is WeeChat syntax, not shell
  add_cmd '/set fifo.file.path "${raw:${weechat_runtime_dir}/weechat_fifo}"'
fi

# Relay settings, enforced on every start: "api" protocol (the one the
# pbtrung/glowing-bear fork speaks) on loopback only (nginx proxies /api to
# it), password from the environment. No TOTP: browsers can't send it on the
# WebSocket connection, so a TOTP secret would lock Glowing Bear out.
add_cmd '/set relay.network.bind_address "127.0.0.1"'
add_cmd '/set relay.network.ipv6 off'
# shellcheck disable=SC2016 # ${...} is WeeChat syntax, not shell
add_cmd '/set relay.network.password "${raw:${env:WEECHAT_RELAY_PASSWORD}}"'
add_cmd '/set relay.network.totp_secret ""'
# PBKDF2 rounds for hashed passwords: 1000 instead of the default 100000, so
# logging in is fast on phones
add_cmd '/set relay.network.password_hash_iterations 1000'
# free port 9001 from the "weechat" protocol relay of older versions of this
# image
add_cmd '/mute /relay del weechat'
add_cmd '/set relay.port.api 9001'
[ -n "$WEECHAT_EXTRA_COMMANDS" ] && add_cmd "$WEECHAT_EXTRA_COMMANDS"
add_cmd '/save'

# Cloudflare Tunnel (remotely managed): routes such as http://localhost:8080
# are configured in the Cloudflare dashboard. cloudflared only makes outbound
# connections, so no inbound port is needed. Its logs go straight to the
# container console. If it exits, stop the container: PID 1 becomes WeeChat
# after the final exec, so wait for that (a fast failure would otherwise
# signal the shell, which PID 1 ignores), then SIGTERM it so WeeChat saves its
# config and quits cleanly.
if [ -n "$CLOUDFLARED_TOKEN" ]; then
  printf "Starting cloudflared tunnel\n"
  (
    status=0
    su-exec weechat cloudflared tunnel --no-autoupdate --loglevel info \
      run --token "$CLOUDFLARED_TOKEN" || status=$?
    printf "cloudflared exited with status %s, stopping container\n" "$status"
    until case "$(cat /proc/1/comm)" in weechat*) true ;; *) false ;; esac; do
      sleep 1
    done
    kill -TERM 1
  ) &
else
  printf "CLOUDFLARED_TOKEN not set, skipping cloudflared\n"
fi

NGINX_CONF="${NGINX_CONF:-/script/nginx.conf}"
printf "Starting nginx with config: %s\n" "$NGINX_CONF"
nginx -c "$NGINX_CONF"

# Headless WeeChat in the foreground as PID 1, logging to the container
# console (--stdout). "--daemon" would fork into the background, and the
# container would exit right away.
printf "Starting WeeChat in %s\n" "$WEECHAT_HOME"
exec su-exec weechat weechat-headless --stdout --dir "$WEECHAT_HOME" \
  --run-command "$CMDS"
