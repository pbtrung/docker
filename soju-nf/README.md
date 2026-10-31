# Manual WeeChat environment on Northflank

This image installs WeeChat with Lua support, tmux, and rclone for manual use. It starts a Twingate
connector and a BusyBox inetd socket listener. inetd launches telnetd only
when a client connects; `/bin/login` authenticates the non-root `soju` account
(UID/GID 1000). No IRC client, bouncer, web server, or backup job starts
automatically.

Mount the persistent volume at `/data`. This is soju's home directory; startup
recursively assigns its contents to soju and grants owner read/write access
(and directory traversal). Existing contents are preserved. WeeChat and rclone
store their normal per-user configuration here.
The bundled `.tmux.conf` is copied to `/data/.tmux.conf` on every startup,
disabling the status bar and mouse support for `soju`.

Set these runtime environment variables, using secrets for passwords/tokens:

| Variable | Purpose |
| --- | --- |
| `SOJU_PASSWORD` | Required login password for `soju`; applied on every start |
| `TWINGATE_NETWORK` | Required Twingate network name |
| `TWINGATE_ACCESS_TOKEN` | Required connector access token |
| `TWINGATE_REFRESH_TOKEN` | Required connector refresh token |
| `TWINGATE_RESOURCE_HOST` | Resource hostname, default `soju.internal` |

The username is fixed as `soju`. Login sessions do not inherit deployment
secrets. Root and the Twingate service account remain locked for password login.

In Northflank, build with Dockerfile `/soju-nf/Dockerfile` and context `/soju-nf`.
Use one instance, attach `/data`, and keep TCP port **23 private**.
Set the runtime hostname to `soju` (`--hostname soju` with Docker). The image
also sets `/etc/hostname` and attempts to apply `soju` at startup; if the
platform blocks hostname changes, it logs a warning and keeps running. Remove the
old ports 8080/6667 and HTTP health check; an exec check can use
`connectorctl health`. `TWINGATE_REF` (default `latest`) selects the connector
image at build time. Both the connector and inetd are supervised; if either
exits the container stops for the platform to restart it.

In Twingate, configure a Resource named `soju.internal` (or the configured
hostname) in this connector's Remote Network, allow TCP port 23, and grant
your account access. The entrypoint maps the hostname to the container's
current IPv4 address.

With your Twingate client connected:

```sh
telnet soju.internal 23
# Log in as soju with SOJU_PASSWORD, then configure things yourself:
tmux new -As irc
weechat
rclone config
```

Telnet carries plaintext credentials inside the encrypted Twingate tunnel;
keep the port private. WeeChat runs in your telnet session and is not
supervised or started on deployment. Old volume files remain available for
manual migration; the image no longer includes soju, gamja, nginx, SQLite
utilities, or the old automatic backup/update scripts.

Socket activation uses Alpine's [BusyBox extras](https://pkgs.alpinelinux.org/package/edge/main/x86_64/busybox-extras).
