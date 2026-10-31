#!/bin/sh
set -eu
umask 077

: "${SOJU_PASSWORD:?Set SOJU_PASSWORD to the telnet password for soju}"
: "${TWINGATE_NETWORK:?Set TWINGATE_NETWORK}"
: "${TWINGATE_ACCESS_TOKEN:?Set TWINGATE_ACCESS_TOKEN}"
: "${TWINGATE_REFRESH_TOKEN:?Set TWINGATE_REFRESH_TOKEN}"
cr="$(printf '\r')"
case "$SOJU_PASSWORD" in
  *"$cr"*|*'
'*) printf 'SOJU_PASSWORD must be a single-line value\n' >&2; exit 1 ;;
esac
if password_update_output="$(printf 'soju:%s\n' "$SOJU_PASSWORD" | chpasswd 2>&1)"; then
  printf '%s\n' "$password_update_output"
else
  printf '%s\n' "$password_update_output" >&2
  exit 1
fi
unset password_update_output
unset SOJU_PASSWORD

# Preserve existing volume contents, granting soju access to all of them.
mkdir -p /data
mkdir -p /data/irssi/logs
if [ ! -f /data/irssi/config ]; then
  python3 /usr/local/bin/convert-weechat.py /data/weechat /data/irssi/config
fi
cp /usr/share/soju/irssi-startup /data/irssi/startup
cp /usr/share/soju/.tmux.conf /data/.tmux.conf
cp /usr/local/bin/backup-irssi.sh /data/backup-irssi.sh
chown -R soju:soju /data
chmod -R u+rwX /data
chmod 700 /data/irssi /data/irssi/logs
chmod 600 /data/irssi/config /data/irssi/startup

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
printf 'Twingate Resource %s is %s (telnet port 23)\n' "$TWINGATE_RESOURCE_HOST" "$pod_ip"

mkdir -p /run/twingate
chown twingate:twingate /run/twingate
chmod 700 /run/twingate

# Keep connector tokens and other deployment secrets out of login sessions.
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /bin/busybox-extras inetd -f /etc/inetd.conf &
inetd_pid=$!
# A persistent HTTP server handles platform probes independently of inetd.
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  su-exec nobody /bin/busybox-extras httpd -f -p 8080 -h /usr/share/health &
health_pid=$!
su-exec twingate /opt/twingate/connectord &
connector_pid=$!
# Run rotation hourly and configuration backup daily, without connector secrets.
# Accept the old backup destination during migration.
printf '0 * * * * /sbin/su-exec soju /usr/bin/python3 /usr/local/bin/rotate-irssi-logs.py\n0 3 * * * /sbin/su-exec soju /usr/local/bin/backup-irssi.sh\n' >/etc/crontabs/root
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  TZ="${TZ:-UTC}" IRSSI_HOME=/data/irssi \
  IRSSI_BACKUP_REMOTE="${IRSSI_BACKUP_REMOTE:-${WEECHAT_BACKUP_REMOTE:-}}" \
  /bin/busybox crond -f -d 8 &
cron_pid=$!
printf 'Scheduling Irssi log maintenance hourly and config backup daily at 03:00\n'
cleanup() {
  kill -TERM "$inetd_pid" "$health_pid" "$connector_pid" ${cron_pid:+"$cron_pid"} 2>/dev/null || true
  wait "$inetd_pid" "$health_pid" "$connector_pid" ${cron_pid:+"$cron_pid"} 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
su-exec soju python3 /usr/local/bin/rotate-irssi-logs.py
# Start detached as soju, with only the environment needed by the client.
# Apply mimalloc to Irssi itself, leaving tmux and the other services alone.
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/data USER=soju LOGNAME=soju TERM=xterm TZ="${TZ:-UTC}" \
  IRSSI_HOME=/data/irssi \
  su-exec soju tmux new-session -d -c /data \
    /usr/local/bin/start-irssi.sh
printf 'Started Irssi in tmux; attach with: tmux a\n'
# Any service exiting stops the container so the platform can restart it.
wait -n "$inetd_pid" "$health_pid" "$connector_pid" ${cron_pid:+"$cron_pid"}
