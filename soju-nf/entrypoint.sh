#!/bin/sh
set -e

# Persistent volume, mounted at /data: the SQLite DB in /data/soju and
# gamja in /data/gamja.
SOJU_DATA_DIR="${SOJU_DATA_DIR:-/data/soju}"
GAMJA_DATA_DIR="${GAMJA_DATA_DIR:-/data/gamja}"
# soju opens the admin socket after startup maintenance: schema migrations
# (e.g. rebuilding a large message table) and the vacuum of message expiry.
startup_timeout="${SOJU_STARTUP_TIMEOUT:-1800}"
case "$startup_timeout" in
  ''|*[!0-9]*|???????*) printf 'SOJU_STARTUP_TIMEOUT must be 0..999999 seconds (0 means unlimited)\n' >&2; exit 1 ;;
esac
SOJU_CONF=/etc/soju/config
export SOJU_CONF

: "${CF_TUNNEL_TOKEN:?Set CF_TUNNEL_TOKEN for Cloudflare Tunnel}"
: "${SSH_PUBLIC_KEY:?Set SSH_PUBLIC_KEY to your Ed25519 public key}"

# The volume is writable by soju, and so by the SSH login (the same
# UID), while this script runs as root: cp, chown and chmod follow symbolic
# links, so a link planted in /data (e.g. backup-soju.sh -> /etc/shadow)
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

# Everything on the volume belongs to soju:soju, whoever copied it in, so
# soju and the SSH login can manage it. Modes are kept, except where
# tightened or opened below. -h: change links themselves, not their targets
# (-R doesn't descend into linked directories).
mkdir -p /data
chown -hR soju:soju /data

refuse_symlink "$SOJU_DATA_DIR"
mkdir -p "$SOJU_DATA_DIR"
# -R: the DB (and its -wal/-shm files) may have been copied in as root, or
# written by another user. Only soju needs to read it (it holds password
# hashes and network secrets), and soju needs to write the directory too,
# for the -wal and -shm files.
# chmod -R skips links below the top directory, which isn't one.
chown -hR soju:soju "$SOJU_DATA_DIR"
chmod -R u+rwX,go-rwx "$SOJU_DATA_DIR"
if [ -f "$SOJU_DATA_DIR/main.db" ]; then
  printf "Using the existing soju database %s\n" "$SOJU_DATA_DIR/main.db"
fi

# soju config: soju.conf is baked into the image. Use SOJU_CONFIG_FILE
# instead if given (e.g. a Northflank secret file).
template="${SOJU_CONFIG_FILE:-/usr/share/soju/config}"
if [ ! -f "$template" ]; then
  printf "SOJU_CONFIG_FILE %s does not exist\n" "$template" >&2
  exit 1
fi
mkdir -p /etc/soju
cp "$template" "$SOJU_CONF"
chmod 644 "$SOJU_CONF"

mkdir -p /run/soju
chown soju:soju /run/soju
chmod 700 /run/soju
rm -f /run/soju/admin

admin_password="${SOJU_ADMIN_PASSWORD:-}"
admin_user="${SOJU_ADMIN_USER:-admin}"
unset SOJU_ADMIN_PASSWORD
cr="$(printf '\r')"
case "$admin_user$admin_password" in
  *"$cr"*|*'
'*) printf 'Admin username and password must be single-line values\n' >&2; exit 1 ;;
esac

# gamja lives on the volume so it can be updated without a new image: run
# update-gamja.sh (copied next to $GAMJA_DATA_DIR) from a shell. Seed it from
# the release baked into the image on the first start; lighttpd serves it
# through the /usr/share/gamja symlink. A link in its place is replaced.
refuse_symlink "$(dirname "$GAMJA_DATA_DIR")"
if [ -L "$GAMJA_DATA_DIR" ] || [ ! -f "$GAMJA_DATA_DIR/index.html" ]; then
  printf "Installing bundled gamja %s in %s\n" \
    "$(cat /usr/share/gamja-dist/.version)" "$GAMJA_DATA_DIR"
  rm -rf "$GAMJA_DATA_DIR"
  mkdir -p "$(dirname "$GAMJA_DATA_DIR")"
  cp -a /usr/share/gamja-dist "$GAMJA_DATA_DIR"
fi
# soju owns gamja, so update-gamja.sh works as soju; lighttpd workers must be
# able to reach and read it.
chown -hR soju:soju "$GAMJA_DATA_DIR"
chmod a+x "$(dirname "$GAMJA_DATA_DIR")"
chmod -R a+rX "$GAMJA_DATA_DIR"
ln -sfn "$GAMJA_DATA_DIR" /usr/share/gamja
UPDATE_GAMJA="$(dirname "$GAMJA_DATA_DIR")/update-gamja.sh"
install_for_soju /usr/local/bin/update-gamja.sh "$UPDATE_GAMJA"

# Daily DB backup with rclone (backup-soju.sh), run by BusyBox crond as
# soju. The script is copied to /data on every start (the image's version
# wins). Cron uses the image copy.
# rclone.conf holds the storage credentials: soju only. crond runs in the
# background, so it and its jobs keep the container's stdout and stderr
# (-d 8: log the jobs it starts to stderr).
install_for_soju /usr/local/bin/backup-soju.sh /data/backup-soju.sh
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/data/rclone.conf}"
SOJU_BACKUP_REMOTE="${SOJU_BACKUP_REMOTE:-}"
if [ -L "$RCLONE_CONFIG_FILE" ]; then
  # Only soju reads it (backup-soju.sh), so leave it alone rather than fail
  printf '%s is a symbolic link; not changing its owner or mode\n' "$RCLONE_CONFIG_FILE" >&2
elif [ -f "$RCLONE_CONFIG_FILE" ]; then
  chown soju:soju "$RCLONE_CONFIG_FILE"
  chmod 600 "$RCLONE_CONFIG_FILE"
fi

mkdir -p /run/soju-backup
chown root:soju /run/soju-backup
chmod 750 /run/soju-backup
printf '%s' "$SOJU_DATA_DIR" >/run/soju-backup/data-dir
printf '%s' "$SOJU_BACKUP_REMOTE" >/run/soju-backup/remote
printf '%s' "$RCLONE_CONFIG_FILE" >/run/soju-backup/rclone-config
chown root:soju /run/soju-backup/*
chmod 640 /run/soju-backup/*

# SSH sessions start from a clean environment: give login shells the
# settings backup-soju.sh and update-gamja.sh need (no secrets), quoted for
# sh and rewritten on every start so changed values don't go stale.
sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
{
  printf '# Written by entrypoint.sh on every start\n'
  printf 'export TZ=%s\n' "$(sh_quote "${TZ:-UTC}")"
  printf 'export SOJU_DATA_DIR=%s\n' "$(sh_quote "$SOJU_DATA_DIR")"
  printf 'export GAMJA_DATA_DIR=%s\n' "$(sh_quote "$GAMJA_DATA_DIR")"
  printf 'export RCLONE_CONFIG_FILE=%s\n' "$(sh_quote "$RCLONE_CONFIG_FILE")"
  printf 'export SOJU_BACKUP_REMOTE=%s\n' "$(sh_quote "$SOJU_BACKUP_REMOTE")"
} >/etc/profile.d/soju-env.sh
chmod 644 /etc/profile.d/soju-env.sh
SOJU_BACKUP_CRON="${SOJU_BACKUP_CRON:-0 3 * * *}"
case "$SOJU_BACKUP_CRON" in
  *"$cr"*|*'
'*) printf 'SOJU_BACKUP_CRON must be a single line\n' >&2; exit 1 ;;
esac
# Install SSH only after volume permissions are set.
/usr/local/bin/setup-ssh.sh
unset SSH_PUBLIC_KEY SSH_USERNAME

# Keep web settings outside the private admin-socket directory.
mkdir -p /run/soju-web
printf '%s\n' "${GAMJA_CONFIG_JSON:-{\"server\":{\"auth\":\"mandatory\",\"ping\":30\}}}" >/run/soju-web/config.json
chmod 755 /run/soju-web
chmod 644 /run/soju-web/config.json
lighttpd -t -f /script/lighttpd.conf

# Supervise soju so bootstrap errors fail the container instead of leaving
# a running service with no admin. Forward shutdown to soju for a clean exit.
soju_pid=
inetd_pid=
lighttpd_pid=
tunnel_pid=
cron_pid=
cleanup() {
  kill -TERM ${soju_pid:+"$soju_pid"} ${inetd_pid:+"$inetd_pid"} ${lighttpd_pid:+"$lighttpd_pid"} ${tunnel_pid:+"$tunnel_pid"} ${cron_pid:+"$cron_pid"} 2>/dev/null || true
  wait ${soju_pid:+"$soju_pid"} ${inetd_pid:+"$inetd_pid"} ${lighttpd_pid:+"$lighttpd_pid"} ${tunnel_pid:+"$tunnel_pid"} ${cron_pid:+"$cron_pid"} 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
run_soju() {
  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/data USER=soju LOGNAME=soju TZ="${TZ:-UTC}" \
    SOJU_CONF="$SOJU_CONF" su-exec soju "$@"
}
printf "Starting %s\n" "$(run_soju soju -version)"
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/data USER=soju LOGNAME=soju TZ="${TZ:-UTC}" \
  su-exec soju soju -config "$SOJU_CONF" &
soju_pid=$!

i=0
while [ ! -S /run/soju/admin ]; do
  if ! kill -0 "$soju_pid" 2>/dev/null; then
    printf 'soju exited before opening the admin socket\n' >&2
    exit 1
  fi
  i=$((i + 1))
  if [ "$startup_timeout" -ne 0 ] && [ "$i" -gt "$startup_timeout" ]; then
    printf 'soju did not open /run/soju/admin within %s seconds\n' "$startup_timeout" >&2
    exit 1
  fi
  sleep 1
done

# Check the account on every start, rather than only on an empty database.
# Only an explicit unknown username permits creation. Other errors are fatal.
if [ -n "$admin_password" ]; then
  if status="$(run_soju sojuctl user status "$admin_user" 2>&1)"; then
    case "$status" in
      "$admin_user (admin"*) printf 'Bootstrap admin already exists; keeping the stored password\n' ;;
      *) printf 'SOJU_ADMIN_USER exists without admin privileges; refusing to overwrite it\n' >&2; exit 1 ;;
    esac
  else
    case "$status" in
      'unknown username '*)
        printf 'Creating the bootstrap admin %s\n' "$admin_user"
        run_soju sojuctl user create \
          -username "$admin_user" -password "$admin_password" -admin
        ;;
      *) printf 'Cannot check bootstrap admin: %s\n' "$status" >&2; exit 1 ;;
    esac
  fi
fi
unset admin_password

env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  lighttpd -D -f /script/lighttpd.conf &
lighttpd_pid=$!
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/nonexistent TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" \
  su-exec cloudflared cloudflared tunnel --no-autoupdate run &
tunnel_pid=$!
unset CF_TUNNEL_TOKEN
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /bin/busybox-extras inetd -f /etc/inetd.conf &
inetd_pid=$!
if [ -n "$SOJU_BACKUP_REMOTE" ]; then
  printf '%s /sbin/su-exec soju /usr/local/bin/backup-soju.sh\n' "$SOJU_BACKUP_CRON" >/etc/crontabs/root
  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TZ="${TZ:-UTC}" SOJU_DATA_DIR="$SOJU_DATA_DIR" \
    RCLONE_CONFIG_FILE="$RCLONE_CONFIG_FILE" SOJU_BACKUP_REMOTE="$SOJU_BACKUP_REMOTE" \
    crond -f -d 8 &
  cron_pid=$!
  printf 'Scheduling soju database backup: %s\n' "$SOJU_BACKUP_CRON"
else
  printf 'SOJU_BACKUP_REMOTE is unset; automatic backups disabled\n'
fi
printf 'Started soju-rs and gamja on port 8080\n'
# An exit of any service stops the container for the platform to restart it.
wait -n "$soju_pid" "$inetd_pid" "$lighttpd_pid" "$tunnel_pid" ${cron_pid:+"$cron_pid"}
