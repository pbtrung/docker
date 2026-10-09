#!/bin/sh
# Install a gamja release build from pbtrung/gamja into the directory
# nginx serves, without rebuilding the image.
# Usage: update-gamja.sh [tag]  (default: the latest release)
#        FORCE=1 update-gamja.sh  (reinstall even if up to date)
set -e

REPO="pbtrung/gamja"
DEST="${GAMJA_DATA_DIR:-/data/gamja}"
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
  printf "gamja %s is already installed in %s\n" "$tag" "$DEST"
  exit 0
fi

# Unpack next to $DEST (same filesystem), so the swap below is two renames
# and nginx never serves a half-extracted tree.
mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp -d "$(dirname "$DEST")/.gamja.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

printf "Downloading %s\n" "$url"
wget -q -O "$tmp/gamja.zip" "$url"
unzip -q "$tmp/gamja.zip" -d "$tmp/unzip"
# Accept index.html at the zip root or inside one top-level folder
# (e.g. gamja/index.html).
if [ -f "$tmp/unzip/index.html" ]; then
  mv "$tmp/unzip" "$tmp/new"
else
  for f in "$tmp"/unzip/*/index.html; do
    [ -f "$f" ] || continue
    if [ -e "$tmp/new" ]; then
      printf "%s has more than one folder with an index.html\n" "$url" >&2
      exit 1
    fi
    mv "$(dirname "$f")" "$tmp/new"
  done
fi
if [ ! -f "$tmp/new/index.html" ]; then
  printf "%s has no index.html at its root or in a top-level folder\n" "$url" >&2
  exit 1
fi
printf "%s\n" "$tag" >"$tmp/new/.version"
chmod -R a+rX "$tmp/new"

rm -rf "$DEST.old"
[ -e "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$tmp/new" "$DEST"
rm -rf "$DEST.old"

printf "Installed gamja %s in %s\n" "$tag" "$DEST"
