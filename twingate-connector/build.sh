#!/bin/sh
# Extract connectord and connectorctl from the official Twingate Docker image
# for amd64 and arm64, update the PKGBUILD (pkgver, image digest, checksums)
# and build the x86_64 and aarch64 packages.
# Usage: ./build.sh [image]   (default: twingate/connector:1)
#
# Both architectures come from the same image index digest, so they're the
# same connector release. The version is read from the amd64 binary.
set -eu

IMAGE="${1:-twingate/connector:1}"
REPO="${IMAGE%:*}"
cd "$(dirname "$0")"

digest="$(docker buildx imagetools inspect "$IMAGE" --format '{{.Manifest.Digest}}')"
printf "%s is %s\n" "$IMAGE" "$digest"

version="$(docker run --rm --platform linux/amd64 --entrypoint /connectord \
  "$REPO@$digest" --version)"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) printf "Unexpected connector version: %s\n" "$version" >&2; exit 1 ;;
esac
printf "Connector version %s\n" "$version"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for pair in amd64:x86_64 arm64:aarch64; do
  platform="${pair%:*}"
  carch="${pair#*:}"
  ctr="$(docker create --platform "linux/$platform" "$REPO@$digest")"
  mkdir -p "$tmp/$carch"
  docker cp -q "$ctr:/connectord" "$tmp/$carch/connectord"
  docker cp -q "$ctr:/connectorctl" "$tmp/$carch/connectorctl"
  docker rm -f "$ctr" >/dev/null
  # Fixed owner and mtime: the same binaries give the same tarball
  tar -C "$tmp/$carch" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime=@0 -cf - connectord connectorctl |
    gzip -n -9 >"twingate-connector-$version-$carch.tar.gz"
  printf "Wrote twingate-connector-%s-%s.tar.gz\n" "$version" "$carch"
done

# A new connector version restarts pkgrel at 1
old="$(sed -n 's/^pkgver=//p' PKGBUILD)"
sed -i "s/^pkgver=.*/pkgver=$version/; s/^_image_digest=.*/_image_digest=$digest/" PKGBUILD
if [ "$old" != "$version" ]; then
  sed -i 's/^pkgrel=.*/pkgrel=1/' PKGBUILD
fi
updpkgsums

PACKAGER="${PACKAGER:-$(git config user.name) <$(git config user.email)>}"
export PACKAGER

makepkg -f -c --noconfirm

# aarch64 on this host: there's nothing to compile, only the architecture
# makepkg packages for changes
conf="$tmp/makepkg-aarch64.conf"
cp /etc/makepkg.conf "$conf"
printf 'CARCH="aarch64"\nCHOST="aarch64-unknown-linux-gnu"\n' >>"$conf"
makepkg -f -c --noconfirm --config "$conf"

ls -l ./*.pkg.tar.zst
