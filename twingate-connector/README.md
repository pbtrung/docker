# Twingate Connector for Arch Linux

Arch Linux packages (`x86_64`, `aarch64`) of the [Twingate Connector],
repackaged from the official `twingate/connector:1` Docker image. Twingate's
`setup.sh` only supports Debian/Ubuntu and RHEL-style distros, and stops on
Arch Linux and Arch Linux ARM with "not supported".

The image's `connectord` and `connectorctl` are linked against glibc,
libgcc_s and libsystemd, which Arch has (`glibc`, `gcc-libs`,
`systemd-libs`): the package installs them unmodified, with a systemd unit.

## Install

Download the package for your architecture from the
[releases](https://github.com/pbtrung/docker/releases) (tags
`twingate-connector-<version>-<pkgrel>`), then:

```sh
sudo pacman -U twingate-connector-<version>-<pkgrel>-$(uname -m).pkg.tar.zst
```

In the Twingate admin console, add a Connector to a Remote Network, choose
any deploy method and generate tokens. Put them, and the network name (the
`<network>` of `<network>.twingate.com`), in `/etc/twingate/connector.conf`
(root only, kept on upgrades):

```
TWINGATE_NETWORK=<network>
TWINGATE_ACCESS_TOKEN=...
TWINGATE_REFRESH_TOKEN=...
```

```sh
sudo systemctl enable --now twingate-connector
journalctl -u twingate-connector -f       # State: Online
sudo twingate-connectorctl health         # OK
```

The connector only makes outbound connections: no port needs to be open,
in a firewall (ufw, the cloud provider's) or anywhere else.

## Package contents

| Path | |
| ---- | - |
| `/usr/lib/twingate-connector/connectord`, `connectorctl` | The binaries from the image, unmodified |
| `/usr/bin/twingate-connectorctl` | `connectorctl` with the service's API socket (`/run/twingate-connector/connector.sock`) |
| `/usr/lib/systemd/system/twingate-connector.service` | Runs `connectord` as a dynamic user with no privileges, restarted whenever it exits |
| `/etc/twingate/connector.conf` | Network name and tokens (mode 600, `backup`) |

The service needs no capabilities: the connector opens TCP connections to
Resources and pings them with unprivileged ICMP sockets
(`net.ipv4.ping_group_range`, open to all groups by systemd's defaults).

## Files

| File | Purpose |
| ---- | ------- |
| `PKGBUILD` | Package definition. Its arch sources are the local tarballs from `build.sh` (not in git or the release); `_image_digest` records the image index they came from |
| `build.sh` | Pulls the image's amd64 and arm64 variants from one index digest, extracts the binaries into `twingate-connector-<version>-<arch>.tar.gz`, updates `pkgver`, `_image_digest` and the checksums, and builds both packages |
| `release.sh` | Creates the GitHub release `twingate-connector-<pkgver>-<pkgrel>` with the two packages |
| `twingate-connector.service`, `twingate-connectorctl`, `connector.conf` | Installed by the package |

## New version

```sh
./build.sh                    # or ./build.sh twingate/connector:<tag>
git add PKGBUILD && git commit -m "twingate-connector: update to <version>" && git push
./release.sh
```

`build.sh` reads the version from the amd64 binary (`connectord --version`)
and resets `pkgrel` to 1 when it changes; bump `pkgrel` by hand for a
packaging-only change. The `aarch64` package is built on an x86_64 host with
`makepkg --config` set to `CARCH=aarch64`: there's nothing to compile. It
needs Docker, `makepkg` and `updpkgsums` (pacman-contrib), and `gh` for the
release.

[Twingate Connector]: https://www.twingate.com/docs/connectors
