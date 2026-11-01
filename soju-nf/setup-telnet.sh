#!/bin/sh
set -eu

: "${TELNET_USERNAME:?Set TELNET_USERNAME for telnet login}"
: "${TELNET_PASSWORD:?Set TELNET_PASSWORD for telnet login}"
case "$TELNET_USERNAME" in
  [a-z_]* ) ;;
  * ) printf 'Invalid TELNET_USERNAME\n' >&2; exit 1 ;;
esac
case "$TELNET_USERNAME" in
  *[!a-z0-9_-]* ) printf 'Invalid TELNET_USERNAME\n' >&2; exit 1 ;;
esac
if [ "${#TELNET_USERNAME}" -gt 32 ]; then
  printf 'TELNET_USERNAME must be at most 32 characters\n' >&2
  exit 1
fi
cr="$(printf '\r')"
case "$TELNET_PASSWORD" in
  *"$cr"*|*'
'*) printf 'TELNET_PASSWORD must be a single-line value\n' >&2; exit 1 ;;
esac

if [ "$TELNET_USERNAME" != soju ]; then
  if awk -F: -v name="$TELNET_USERNAME" '$1 == name { found=1 } END { exit !found }' /etc/passwd; then
    # Allow restarting the same container with the already-created alias.
    if ! awk -F: -v name="$TELNET_USERNAME" '$1 == name && $3 == 1000 && $4 == 1000 && $6 == "/data" && $7 == "/bin/ash" { valid=1 } END { exit !valid }' /etc/passwd; then
      printf 'TELNET_USERNAME conflicts with an existing system account\n' >&2
      exit 1
    fi
  else
    # Alias the service UID/GID so both logins can edit the same private files,
    # including files created later by WeeChat with mode 600. Never grant root.
    printf '%s:x:1000:1000::/data:/bin/ash\n' "$TELNET_USERNAME" >>/etc/passwd
    printf '%s:!:0:0:99999:7:::\n' "$TELNET_USERNAME" >>/etc/shadow
  fi
fi
# Credential changes must not leave an old alias usable after a container restart.
awk -F: -v name="$TELNET_USERNAME" '$3 == 1000 && $1 != name { print $1 }' /etc/passwd |
while IFS= read -r account; do
  if ! passwd -l "$account" >/dev/null 2>&1; then
    printf 'Cannot lock inactive telnet login\n' >&2
    exit 1
  fi
done
if ! printf '%s:%s\n' "$TELNET_USERNAME" "$TELNET_PASSWORD" | chpasswd >/dev/null 2>&1; then
  printf 'Cannot configure telnet login password\n' >&2
  exit 1
fi
printf 'Telnet login configured on private port 23\n'
