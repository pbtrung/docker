#!/bin/sh
# Publish the tarballs and packages from build.sh as a GitHub release,
# tagged twingate-connector-<pkgver>-<pkgrel>: the PKGBUILD's sources point
# there. Commit and push the PKGBUILD first, so the tag matches it.
set -eu

cd "$(dirname "$0")"

pkgver="$(sed -n 's/^pkgver=//p' PKGBUILD)"
pkgrel="$(sed -n 's/^pkgrel=//p' PKGBUILD)"
digest="$(sed -n 's/^_image_digest=//p' PKGBUILD)"
tag="twingate-connector-$pkgver-$pkgrel"

if ! git diff --quiet HEAD -- . || [ -n "$(git status --porcelain -- PKGBUILD)" ]; then
  printf "Commit the changes in %s first\n" "$PWD" >&2
  exit 1
fi
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
  printf "Push the current branch first\n" >&2
  exit 1
fi

set -- \
  "twingate-connector-$pkgver-x86_64.tar.gz" \
  "twingate-connector-$pkgver-aarch64.tar.gz" \
  "twingate-connector-$pkgver-$pkgrel-x86_64.pkg.tar.zst" \
  "twingate-connector-$pkgver-$pkgrel-aarch64.pkg.tar.zst"
for f in "$@"; do
  [ -f "$f" ] || { printf "Missing %s: run ./build.sh\n" "$f" >&2; exit 1; }
done

notes="Twingate Connector $pkgver for Arch Linux (x86_64, aarch64), repackaged
from the official Docker image \`twingate/connector@$digest\`.

\`\`\`sh
sudo pacman -U twingate-connector-$pkgver-$pkgrel-\$(uname -m).pkg.tar.zst
\`\`\`

The \`.tar.gz\` files hold the extracted \`connectord\` and \`connectorctl\`:
the PKGBUILD's sources."

gh release create "$tag" --target "$(git rev-parse HEAD)" \
  --title "twingate-connector $pkgver-$pkgrel" --notes "$notes" "$@"
