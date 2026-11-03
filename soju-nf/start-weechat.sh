#!/bin/sh
set -eu
: "${WEECHAT_RELAY_PASSWORD:?Set WEECHAT_RELAY_PASSWORD for Glowing Bear login}"
WEECHAT_HOME="${WEECHAT_HOME:-/data/weechat}"
WEECHAT_MALLOC="${WEECHAT_MALLOC:-musl}"
case "$WEECHAT_MALLOC" in
  musl|mimalloc) ;;
  *) printf 'WEECHAT_MALLOC must be musl or mimalloc\n' >&2; exit 1 ;;
esac

# Plugins a headless WeeChat behind a relay doesn't need: script
# interpreters (Lua stays installed: /plugin load lua), xfer, and the
# interactive or terminal-only ones (spell loads dictionaries, buflist keeps
# rebuilding a bar nobody sees). Kept: irc, relay, logger, fifo, trigger,
# alias, charset.
EXCLUDED_PLUGINS="python perl ruby lua tcl guile javascript php xfer spell buflist fset script typing exec"
plugins="*"
for plugin in $EXCLUDED_PLUGINS; do
  plugins="$plugins,!$plugin"
done

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

# Apply to existing volumes too. Memory: keep 200 lines per buffer (logs
# keep the rest on disk) and don't load log lines into buffers as they open.
# Plugins autoload before --run-command, so unload the excluded ones on this
# start as well.
add_cmd '/set weechat.history.max_buffer_lines_number 200'
add_cmd '/set logger.look.backlog 0'
add_cmd "/set weechat.plugin.autoload \"$plugins\""
for plugin in $EXCLUDED_PLUGINS; do
  add_cmd "/mute /plugin unload $plugin"
done
# Relay settings, enforced on every start: "api" protocol (the one the
# pbtrung/glowing-bear fork speaks) on loopback only (lighttpd proxies /api to
# it), password from the environment. No TOTP: browsers can't send it on the
# WebSocket connection, so a TOTP secret would lock Glowing Bear out.
# Older terminal-only configurations excluded relay from plugin.autoload.
# Changing autoload above only affects the next start; load it now as well.
add_cmd '/mute /plugin load relay'
add_cmd '/mute /plugin load fifo'
add_cmd '/set fifo.file.path "${raw:${weechat_runtime_dir}/weechat_fifo}"'
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
[ -n "${WEECHAT_EXTRA_COMMANDS:-}" ] && add_cmd "$WEECHAT_EXTRA_COMMANDS"
add_cmd '/save'

# Allocator: musl's by default, which keeps less memory resident for a
# long-running, mostly idle process. WEECHAT_MALLOC=mimalloc preloads
# mimalloc instead, returning freed memory to the system right away
# (MIMALLOC_PURGE_DELAY=0) rather than holding it for reuse.
if [ "$WEECHAT_MALLOC" = mimalloc ]; then
  export LD_PRELOAD=/usr/lib/libmimalloc.so.3 MIMALLOC_PURGE_DELAY=0
fi
exec weechat-headless --stdout --no-script --plugins "$plugins" \
  --dir "$WEECHAT_HOME" --run-command "$CMDS"
