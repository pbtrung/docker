#!/bin/sh
set -eu

: "${WEECHAT_RELAY_PASSWORD:?Set WEECHAT_RELAY_PASSWORD for Glowing Bear login}"
: "${CF_TUNNEL_TOKEN:?Set CF_TUNNEL_TOKEN for Cloudflare Tunnel}"
/usr/local/bin/setup-telnet.sh
unset TELNET_USERNAME TELNET_PASSWORD

# The volume is writable by soju, and so by the telnet login (the same
# UID), while this script runs as root: cp, chown and chmod follow symbolic
# links, so a link planted in /data (e.g. backup-weechat.sh -> /etc/shadow)
# would redirect root's writes on the next start. Never write through a link
# there: refuse or replace links, and copy files in fresh. No soju process
# runs yet, so nothing can swap a path between a check and its use.
refuse_symlink() {
  if [ -L "$1" ]; then
    printf '%s is a symbolic link; refusing to use it as root\n' "$1" >&2
    exit 1
  fi
}
# Install a fresh copy of $1 at $2, owned by soju: rm first, so cp creates a
# new file instead of writing through whatever is at $2.
install_for_soju() {
  rm -f "$2"
  cp "$1" "$2"
  chown -h soju:soju "$2"
  chmod 755 "$2"
}

# Preserve existing volume contents, granting soju access to all of them.
# -h: change links themselves, not their targets (-R doesn't descend into
# linked directories, and chmod -R skips links below the top directory).
mkdir -p /data
WEECHAT_HOME="${WEECHAT_HOME:-/data/weechat}"
refuse_symlink "$WEECHAT_HOME"
mkdir -p "$WEECHAT_HOME"
chown -hR soju:soju "$WEECHAT_HOME"
chmod -R u+rwX "$WEECHAT_HOME"
install_for_soju /usr/local/bin/backup-weechat.sh /data/backup-weechat.sh
chown -hR soju:soju /data
chmod -R u+rwX /data

# Share only backup settings with soju, not the deployment environment.
# Recreate on every start so changed or removed values cannot become stale.
mkdir -p /run/soju-backup
chown root:soju /run/soju-backup
chmod 750 /run/soju-backup
(umask 077
  printf '%s' "${WEECHAT_BACKUP_REMOTE:-}" >/run/soju-backup/remote
  printf '%s' "$WEECHAT_HOME" >/run/soju-backup/weechat-home
)
chown root:soju /run/soju-backup/remote /run/soju-backup/weechat-home
chmod 640 /run/soju-backup/remote /run/soju-backup/weechat-home

# Keep the web client on the volume so it can be updated from a shell.
# A link in its place is replaced with the bundled copy.
if [ -L /data/glowing-bear ] || [ ! -f /data/glowing-bear/index.html ]; then
  rm -f /data/glowing-bear 2>/dev/null || true
  mkdir -p /data/glowing-bear
  cp -a /usr/share/glowing-bear-dist/. /data/glowing-bear/
fi
chown -hR soju:soju /data/glowing-bear
chmod -R u+rwX /data/glowing-bear
ln -sfn /data/glowing-bear /usr/share/glowing-bear
install_for_soju /usr/local/bin/update-glowing-bear.sh /data/update-glowing-bear.sh

# No deployment secrets are inherited by telnet sessions.
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /bin/busybox-extras inetd -f /etc/inetd.conf &
inetd_pid=$!

# nginx serves Glowing Bear, /healthz, and the loopback WeeChat API relay.
nginx -t -c /script/nginx.conf
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  nginx -c /script/nginx.conf -g 'daemon off;' &
nginx_pid=$!
# Only cloudflared receives the tunnel token; keep it out of command arguments.
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/nonexistent TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" \
  su-exec cloudflared cloudflared tunnel --no-autoupdate run &
tunnel_pid=$!
unset CF_TUNNEL_TOKEN
# Jobs read backup settings from /run/soju-backup, including in a clean login.
cron_pid=
if [ -n "${WEECHAT_BACKUP_REMOTE:-}" ]; then
  printf '0 3 * * * /sbin/su-exec soju /usr/local/bin/backup-weechat.sh\n' >/etc/crontabs/root
  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TZ="${TZ:-UTC}" DATA_DIR=/data \
    /bin/busybox crond -f -d 8 &
  cron_pid=$!
  printf 'Scheduling WeeChat config backup daily at 03:00\n'
else
  printf 'WEECHAT_BACKUP_REMOTE is unset; automatic backups disabled\n'
fi
weechat_pid=
cleanup() {
  kill -TERM "$inetd_pid" "$nginx_pid" "$tunnel_pid" ${weechat_pid:+"$weechat_pid"} ${cron_pid:+"$cron_pid"} 2>/dev/null || true
  wait "$inetd_pid" "$nginx_pid" "$tunnel_pid" ${weechat_pid:+"$weechat_pid"} ${cron_pid:+"$cron_pid"} 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# Start headless as soju; only WeeChat receives the relay password.
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/data USER=soju LOGNAME=soju TZ="${TZ:-UTC}" \
  WEECHAT_HOME="$WEECHAT_HOME" WEECHAT_RELAY_PASSWORD="$WEECHAT_RELAY_PASSWORD" \
  WEECHAT_EXTRA_COMMANDS="${WEECHAT_EXTRA_COMMANDS:-}" \
  WEECHAT_MALLOC="${WEECHAT_MALLOC:-musl}" \
  su-exec soju /usr/local/bin/start-weechat.sh &
weechat_pid=$!
unset WEECHAT_RELAY_PASSWORD
printf 'Started headless WeeChat and Glowing Bear on port 8080\n'
# Any service exiting stops the container so the platform can restart it.
wait -n "$inetd_pid" "$nginx_pid" "$tunnel_pid" ${weechat_pid:+"$weechat_pid"} ${cron_pid:+"$cron_pid"}
