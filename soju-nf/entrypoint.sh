#!/bin/sh
set -eu

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
cp /usr/share/soju/.tmux.conf /data/.tmux.conf
cp /usr/local/bin/backup-weechat.sh /data/backup-weechat.sh
chown -R soju:soju /data
chmod -R u+rwX /data

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
# Keep only backup settings in the cron environment, never connector tokens.
cron_pid=
if [ -n "${WEECHAT_BACKUP_REMOTE:-}" ]; then
  printf '0 3 * * * /sbin/su-exec soju /usr/local/bin/backup-weechat.sh\n' >/etc/crontabs/root
  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TZ="${TZ:-UTC}" DATA_DIR=/data \
    WEECHAT_HOME="${WEECHAT_HOME:-/data/weechat}" \
    WEECHAT_BACKUP_REMOTE="$WEECHAT_BACKUP_REMOTE" \
    /bin/busybox crond -f -d 8 &
  cron_pid=$!
  printf 'Scheduling WeeChat config backup daily at 03:00\n'
else
  printf 'WEECHAT_BACKUP_REMOTE is unset; automatic backups disabled\n'
fi
cleanup() {
  kill -TERM "$inetd_pid" "$health_pid" "$connector_pid" ${cron_pid:+"$cron_pid"} 2>/dev/null || true
  wait "$inetd_pid" "$health_pid" "$connector_pid" ${cron_pid:+"$cron_pid"} 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# Any service exiting stops the container so the platform can restart it.
wait -n "$inetd_pid" "$health_pid" "$connector_pid" ${cron_pid:+"$cron_pid"}
