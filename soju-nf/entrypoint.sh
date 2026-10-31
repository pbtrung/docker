#!/bin/sh
set -eu

# Changing the kernel hostname may be restricted by the hosting platform.
if [ "$(hostname)" != soju ] && ! hostname soju; then
  printf 'Cannot set hostname: configure the runtime hostname as soju\n' >&2
fi

: "${SOJU_PASSWORD:?Set SOJU_PASSWORD to the telnet password for soju}"
: "${TWINGATE_NETWORK:?Set TWINGATE_NETWORK}"
: "${TWINGATE_ACCESS_TOKEN:?Set TWINGATE_ACCESS_TOKEN}"
: "${TWINGATE_REFRESH_TOKEN:?Set TWINGATE_REFRESH_TOKEN}"
cr="$(printf '\r')"
case "$SOJU_PASSWORD" in
  *"$cr"*|*'
'*) printf 'SOJU_PASSWORD must be a single-line value\n' >&2; exit 1 ;;
esac
printf 'soju:%s\n' "$SOJU_PASSWORD" | chpasswd
unset SOJU_PASSWORD

# Preserve existing volume contents, granting soju access to all of them.
mkdir -p /data
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
su-exec twingate /opt/twingate/connectord &
connector_pid=$!
cleanup() {
  kill -TERM "$inetd_pid" "$connector_pid" 2>/dev/null || true
  wait "$inetd_pid" "$connector_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# Either service exiting stops the container so the platform can restart it.
wait -n "$inetd_pid" "$connector_pid"
