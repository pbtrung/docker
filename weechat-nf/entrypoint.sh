#!/bin/sh
set -e

# Persistent volume: WeeChat config, logs, scripts. Mount a Northflank
# volume here.
DATA_DIR="${DATA_DIR:-/data}"
export WEECHAT_HOME="${WEECHAT_HOME:-$DATA_DIR/weechat}"

: "${TTYD_PASSWORD:?TTYD_PASSWORD is required (browser terminal password)}"
: "${WEECHAT_BACKUP_REMOTE:?WEECHAT_BACKUP_REMOTE is required (rclone upload destination)}"

SHELL_HOME="$DATA_DIR/home"
mkdir -p "$WEECHAT_HOME" "$SHELL_HOME" /run/weechat
chown weechat:weechat "$DATA_DIR" "$WEECHAT_HOME" "$SHELL_HOME" /run/weechat
chmod 700 /run/weechat
# grml-zsh-config is loaded system-wide by Alpine's /etc/zsh/zshrc.
# Keep custom startup files, completion cache and history on the volume.
export ZDOTDIR="$SHELL_HOME"
if [ ! -f "$SHELL_HOME/.zshrc" ]; then
  cp /etc/skel/.zshrc "$SHELL_HOME/.zshrc"
  chown weechat:weechat "$SHELL_HOME/.zshrc"
fi
cp /usr/local/bin/backup-weechat.sh "$DATA_DIR/backup-weechat.sh"
chmod +x "$DATA_DIR/backup-weechat.sh"

# Hash the browser password before starting any long-lived processes.
TTYD_PASSWORD_HASH="$(printf '%s\n' "$TTYD_PASSWORD" | ttyd-rs --hash-password)"
unset TTYD_PASSWORD

# WeeChat commands run after startup (-r).
CMDS=""
add_cmd() {
  CMDS="${CMDS:+$CMDS;}$1"
}

# Sensible defaults, only on the very first start (no weechat.conf yet), so
# that later changes made in WeeChat are kept.
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

# Apply to existing volumes too. start-weechat.sh also excludes these
# plugins on the command line, before any saved configuration is loaded.
# Lua stays installed and can be loaded explicitly with /plugin load lua.
add_cmd '/set weechat.history.max_buffer_lines_number 500'
add_cmd '/set weechat.plugin.autoload "*,!relay,!python,!perl,!ruby,!lua,!tcl,!guile,!javascript,!php,!xfer"'
[ -n "$WEECHAT_EXTRA_COMMANDS" ] && add_cmd "$WEECHAT_EXTRA_COMMANDS"
add_cmd '/save'
export WEECHAT_STARTUP_COMMANDS="$CMDS"

weechat_tmux() {
  su-exec weechat env HOME="$SHELL_HOME" SHELL=/bin/zsh \
    tmux -S /run/weechat/tmux.sock "$@"
}

weechat_pid=
ttyd_pid=
nginx_pid=
cron_pid=
twingate_pid=
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  trap - EXIT INT TERM
  printf "Stopping WeeChat and terminal services\n"
  # The tmux server is detached, so container signals must reach WeeChat
  # explicitly. Give it time to save before closing the remaining windows.
  if [ -n "$weechat_pid" ]; then
    kill -TERM "$weechat_pid" 2>/dev/null || true
    remaining=15
    while kill -0 "$weechat_pid" 2>/dev/null && [ "$remaining" -gt 0 ]; do
      sleep 1
      remaining=$((remaining - 1))
    done
  fi
  weechat_tmux kill-server 2>/dev/null || true
  for child in "$ttyd_pid" "$nginx_pid" "$cron_pid" "$twingate_pid"; do
    [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true
  done
  wait || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM

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
    connector_pid=
    trap '[ -z "$connector_pid" ] || kill "$connector_pid" 2>/dev/null; wait; exit 0' INT TERM
    while :; do
      su-exec twingate /opt/twingate/connectord &
      connector_pid=$!
      wait "$connector_pid" || true
      printf "Twingate connector exited, restarting in 5 s\n"
      sleep 5 &
      connector_pid=$!
      wait "$connector_pid" || true
    done
  ) &
  twingate_pid=$!
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
cron_pid=$!

# Start WeeChat before any browser connects. Closing/reloading a browser
# only detaches its tmux client; WeeChat and IRC connections stay alive.
printf "Starting curses WeeChat in tmux, home: %s\n" "$WEECHAT_HOME"
weechat_pid="$(weechat_tmux new-session -d -s weechat -n weechat \
  -c "$SHELL_HOME" -x 120 -y 36 -P -F '#{pane_pid}' /script/start-weechat.sh)"
weechat_tmux new-window -d -t weechat: -n shell -c "$SHELL_HOME"

printf "Starting ttyd-rs on 127.0.0.1:7681\n"
su-exec weechat env HOME="$SHELL_HOME" SHELL=/bin/zsh \
  ttyd-rs --config /script/ttyd-rs.toml --working-dir "$SHELL_HOME" \
    --auth --username "${TTYD_USERNAME:-weechat}" --password "$TTYD_PASSWORD_HASH" &
ttyd_pid=$!
unset TTYD_PASSWORD_HASH

NGINX_CONF="${NGINX_CONF:-/script/nginx.conf}"
printf "Starting nginx with config: %s\n" "$NGINX_CONF"
nginx -c "$NGINX_CONF" -g 'daemon off;' &
nginx_pid=$!

# Stop the container if a core service exits, so Northflank can restart it.
while kill -0 "$weechat_pid" 2>/dev/null &&
      kill -0 "$ttyd_pid" 2>/dev/null &&
      kill -0 "$nginx_pid" 2>/dev/null &&
      kill -0 "$cron_pid" 2>/dev/null; do
  sleep 1 &
  wait $! || true
done
printf "A WeeChat or terminal service exited\n" >&2
exit 1
