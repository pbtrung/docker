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
: "${WEECHAT_BACKUP_REMOTE:?WEECHAT_BACKUP_REMOTE is required (rclone upload destination)}"

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
cp /usr/local/bin/backup-weechat.sh "$DATA_DIR/backup-weechat.sh"
chmod +x "$DATA_DIR/backup-weechat.sh"

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

# Apply to existing volumes too. Plugins autoload before --run-command, so
# unload the excluded interpreters on this start as well. Lua stays
# installed and can be loaded explicitly with /plugin load lua.
add_cmd '/set weechat.history.max_buffer_lines_number 500'
add_cmd '/set weechat.plugin.autoload "*,!python,!perl,!ruby,!lua,!tcl,!guile,!javascript,!php,!xfer"'
for plugin in python perl ruby lua tcl guile javascript php xfer; do
  add_cmd "/mute /plugin unload $plugin"
done
# Relay settings, enforced on every start: "api" protocol (the one the
# pbtrung/glowing-bear fork speaks) on loopback only (nginx proxies /api to
# it), password from the environment. No TOTP: browsers can't send it on the
# WebSocket connection, so a TOTP secret would lock Glowing Bear out.
# Older terminal-only configurations excluded relay from plugin.autoload.
# Changing autoload above only affects the next start; load it now as well.
add_cmd '/mute /plugin load relay'
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

# Twingate makes outbound connections only; keep port 8080 private on
# Northflank. Unlike Fly, the container can't add a fixed loopback IP, so
# map the Resource hostname to its current IPv4 address on every start.
if [ -n "$TWINGATE_NETWORK" ] && [ -n "$TWINGATE_ACCESS_TOKEN" ] && [ -n "$TWINGATE_REFRESH_TOKEN" ]; then
  TWINGATE_RESOURCE_HOST="${TWINGATE_RESOURCE_HOST:-weechat.internal}"
  pod_ip="$(ip -4 route get 1.1.1.1 2>/dev/null |
    sed -n 's/.* src \([0-9.]*\).*/\1/p')"
  if [ -n "$pod_ip" ] &&
    { awk -v host="$TWINGATE_RESOURCE_HOST" '
        { for (i = 2; i <= NF && $i !~ /^#/; i++) if ($i == host) next; print }
      ' /etc/hosts
      printf "%s\t%s\n" "$pod_ip" "$TWINGATE_RESOURCE_HOST"; } >/tmp/twingate-hosts &&
    cat /tmp/twingate-hosts >/etc/hosts; then
    printf "Twingate Resource %s is %s\n" "$TWINGATE_RESOURCE_HOST" "$pod_ip"
  else
    printf "Can't map %s in /etc/hosts\n" "$TWINGATE_RESOURCE_HOST" >&2
    exit 1
  fi
  rm -f /tmp/twingate-hosts

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
# Only the connector needs the tokens.
unset TWINGATE_ACCESS_TOKEN TWINGATE_REFRESH_TOKEN

# Run the config backup and rotated-log cleanup daily in the container's
# time zone. Keep crond and its jobs attached to the container logs.
printf '0 3 * * * "%s/backup-weechat.sh"\n' "$DATA_DIR" >/etc/crontabs/root
printf "Scheduling the WeeChat backup daily at 03:00\n"
busybox crond -f -d 8 &

NGINX_CONF="${NGINX_CONF:-/script/nginx.conf}"
printf "Starting nginx with config: %s\n" "$NGINX_CONF"
nginx -c "$NGINX_CONF"

# Headless WeeChat in the foreground as PID 1, logging to the container
# console (--stdout). "--daemon" would fork into the background, and the
# container would exit right away.
printf "Starting WeeChat in %s\n" "$WEECHAT_HOME"
exec su-exec weechat env LD_PRELOAD=/usr/lib/libmimalloc.so.3 \
  weechat-headless --stdout --dir "$WEECHAT_HOME" \
  --run-command "$CMDS"
