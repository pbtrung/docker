#!/bin/sh
set -eu

: "${WEECHAT_RELAY_PASSWORD:?Set WEECHAT_RELAY_PASSWORD for Glowing Bear login}"
: "${TWINGATE_NETWORK:?Set TWINGATE_NETWORK}"
: "${TWINGATE_ACCESS_TOKEN:?Set TWINGATE_ACCESS_TOKEN}"
: "${TWINGATE_REFRESH_TOKEN:?Set TWINGATE_REFRESH_TOKEN}"
# Preserve existing volume contents, granting soju access to all of them.
mkdir -p /data
WEECHAT_HOME="${WEECHAT_HOME:-/data/weechat}"
mkdir -p "$WEECHAT_HOME"
chown -R soju:soju "$WEECHAT_HOME"
chmod -R u+rwX "$WEECHAT_HOME"
cp /usr/share/soju/.tmux.conf /data/.tmux.conf
cp /usr/local/bin/backup-weechat.sh /data/backup-weechat.sh
chown -R soju:soju /data
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
if [ ! -f /data/glowing-bear/index.html ]; then
  mkdir -p /data/glowing-bear
  cp -a /usr/share/glowing-bear-dist/. /data/glowing-bear/
fi
chown -R soju:soju /data/glowing-bear
chmod -R u+rwX /data/glowing-bear
ln -sfn /data/glowing-bear /usr/share/glowing-bear
cp /usr/local/bin/update-glowing-bear.sh /data/update-glowing-bear.sh
chown soju:soju /data/update-glowing-bear.sh

TWINGATE_RESOURCE_HOST="${TWINGATE_RESOURCE_HOST:-soju.internal}"
case "$TWINGATE_RESOURCE_HOST" in
  ''|*[!a-zA-Z0-9.-]*) printf 'Invalid TWINGATE_RESOURCE_HOST\n' >&2; exit 1 ;;
esac
pod_ip="$(ip -4 route get 1.1.1.1 |
  sed -n 's/.* src \([0-9.]*\).*/\1/p')"
if [ -z "$pod_ip" ]; then
  printf 'Cannot determine container IPv4 address\n' >&2
  exit 1
fi
awk -v host="$TWINGATE_RESOURCE_HOST" '
  { keep=1; for (i=2; i<=NF; i++) if ($i==host) keep=0; if (keep) print }
' /etc/hosts >/tmp/twingate-hosts
printf '%s\t%s\n' "$pod_ip" "$TWINGATE_RESOURCE_HOST" >>/tmp/twingate-hosts
cat /tmp/twingate-hosts >/etc/hosts
rm -f /tmp/twingate-hosts
printf 'Twingate Resource %s is %s (web port 8080)\n' "$TWINGATE_RESOURCE_HOST" "$pod_ip"

mkdir -p /run/twingate
chown twingate:twingate /run/twingate
chmod 700 /run/twingate

# nginx serves Glowing Bear, /healthz, and the loopback WeeChat API relay.
nginx -t -c /script/nginx.conf
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  nginx -c /script/nginx.conf -g 'daemon off;' &
nginx_pid=$!
su-exec twingate /opt/twingate/connectord &
connector_pid=$!
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
  kill -TERM "$nginx_pid" "$connector_pid" ${weechat_pid:+"$weechat_pid"} ${cron_pid:+"$cron_pid"} 2>/dev/null || true
  wait "$nginx_pid" "$connector_pid" ${weechat_pid:+"$weechat_pid"} ${cron_pid:+"$cron_pid"} 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# Start headless as soju; only WeeChat receives the relay password and mimalloc.
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/data USER=soju LOGNAME=soju TZ="${TZ:-UTC}" \
  WEECHAT_HOME="$WEECHAT_HOME" WEECHAT_RELAY_PASSWORD="$WEECHAT_RELAY_PASSWORD" \
  WEECHAT_EXTRA_COMMANDS="${WEECHAT_EXTRA_COMMANDS:-}" \
  su-exec soju /usr/local/bin/start-weechat.sh &
weechat_pid=$!
unset WEECHAT_RELAY_PASSWORD
printf 'Started headless WeeChat and Glowing Bear on port 8080\n'
# Any service exiting stops the container so the platform can restart it.
wait -n "$nginx_pid" "$connector_pid" ${weechat_pid:+"$weechat_pid"} ${cron_pid:+"$cron_pid"}
