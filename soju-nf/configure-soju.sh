#!/bin/sh
# Render the private runtime config. Never print its token-bearing contents.
set -eu

: "${TURSO_ORGANIZATION:?Set TURSO_ORGANIZATION}"
: "${TURSO_GROUP:?Set TURSO_GROUP}"
: "${TURSO_GROUP_TOKEN:?Set TURSO_GROUP_TOKEN}"
: "${TURSO_API_TOKEN:?Set TURSO_API_TOKEN}"
TURSO_CONTROLLER="${TURSO_CONTROLLER:-soju-controller}"

template="${SOJU_CONFIG_FILE:-/usr/share/soju/config}"
output=/etc/soju/config
if [ ! -f "$template" ] || [ "$template" = "$output" ]; then
  printf 'SOJU_CONFIG_FILE must be an existing template outside %s\n' "$output" >&2
  exit 1
fi
# Storage settings belong to the environment; a custom template must keep
# message-store turso and must not contain a local DB or embedded tokens.
if grep -Eq '^[[:space:]]*(db|turso-[^[:space:]]*)[[:space:]]' "$template"; then
  printf 'Remove db and turso-* directives from the config template; use TURSO_* environment variables\n' >&2
  exit 1
fi

cr="$(printf '\r')"
directive() {
  case "$2" in
    *"$cr"*|*'
'*) printf '%s must be a single line\n' "$1" >&2; exit 1 ;;
  esac
  # SCFG double-quoted strings escape backslashes and double quotes.
  value="$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '%s "%s"\n' "$1" "$value"
}

umask 077
mkdir -p /etc/soju
chown root:soju /etc/soju
chmod 750 /etc/soju
tmp="$(mktemp /etc/soju/config.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
cat "$template" >"$tmp"
{
  printf '\n'
  directive turso-organization "$TURSO_ORGANIZATION"
  directive turso-group "$TURSO_GROUP"
  directive turso-controller "$TURSO_CONTROLLER"
  directive turso-group-token "$TURSO_GROUP_TOKEN"
  directive turso-api-token "$TURSO_API_TOKEN"
} >>"$tmp"
chown soju:soju "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$output"
