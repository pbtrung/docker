#!/bin/sh
# Install a Glowing Bear release build from pbtrung/glowing-bear into the
# directory nginx serves, without rebuilding the image.
# Usage: update-glowing-bear.sh [tag]   (default: the latest release)
#        FORCE=1 update-glowing-bear.sh  (reinstall even if up to date)
set -e

REPO="pbtrung/glowing-bear"
DEST="${GLOWING_BEAR_DIR:-${DATA_DIR:-/data}/glowing-bear}"
TAG="${1:-latest}"

if [ "$TAG" = "latest" ]; then
  API="https://api.github.com/repos/$REPO/releases/latest"
else
  API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
fi

json="$(wget -q -O - "$API")" || {
  printf "Can't fetch release info from %s\n" "$API" >&2
  exit 1
}
tag="$(printf "%s\n" "$json" |
  sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
url="$(printf "%s\n" "$json" |
  sed -n 's/.*"browser_download_url": *"\([^"]*\.zip\)".*/\1/p' | head -n 1)"
if [ -z "$tag" ] || [ -z "$url" ]; then
  printf "No .zip asset found in release %s of %s\n" "$TAG" "$REPO" >&2
  exit 1
fi

if [ -z "$FORCE" ] && [ "$(cat "$DEST/.version" 2>/dev/null)" = "$tag" ]; then
  printf "Glowing Bear %s is already installed in %s\n" "$tag" "$DEST"
  exit 0
fi

# Unpack next to $DEST (same filesystem), so the swap below is two renames
# and nginx never serves a half-extracted tree.
mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp -d "$(dirname "$DEST")/.glowing-bear.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

printf "Downloading %s\n" "$url"
wget -q -O "$tmp/glowing-bear.zip" "$url"
unzip -q "$tmp/glowing-bear.zip" -d "$tmp/new"
if [ ! -f "$tmp/new/index.html" ]; then
  printf "%s has no index.html at its root\n" "$url" >&2
  exit 1
fi
printf "%s\n" "$tag" >"$tmp/new/.version"
chmod -R a+rX "$tmp/new"

rm -rf "$DEST.old"
[ -e "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$tmp/new" "$DEST"
rm -rf "$DEST.old"

printf "Installed Glowing Bear %s in %s\n" "$tag" "$DEST"
