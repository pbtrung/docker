# soju-rs + gamja on Fly.io

The soju and gamja setup from [soju-nf](../soju-nf), using WireGuard
`cfmesh` for private access. lighttpd serves gamja on port 8080 and proxies
`/socket` to soju on `127.0.0.1:8081`. Plain IRC listens on port 6667.
`/test.html` serves the lighttpd test page; `/healthz` returns `ok`.
Logs go to stdout/stderr, retaining the Fly logging permission fix.

Fly runs one always-on 256 MB machine in `iad`, with no public service and
a 1 GB volume `soju_data` mounted at `/data`. The database remains at
`/data/soju/main.db`; existing users, networks, and history are reused.
Gamja lives at `/data/gamja`. There is no backup job or snapshot retention.
The SQLite CLI is not installed; soju-rs includes its SQLite support.

The image downloads static musl binaries from `pbtrung/soju-rs` and gamja
from `pbtrung/gamja`, matching soju-nf. Build arguments `SOJU_REF` and
`GAMJA_REF` default to `latest`; amd64 and arm64 are supported. soju's
release archive is checked against its `SHA256SUMS`.

## App name

Run commands from this directory. Keep `FLY_APP` in the git-ignored
`.env`: `soju-` followed by exactly 23 random lowercase letters or digits.
To generate a new name (once, before creating the app):

```sh
python3 -c 'import secrets, string; print("FLY_APP=soju-" + "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(23)))' > .env
```

Load it before running Fly commands (bash/zsh):

```sh
set -a
. ./.env
set +a
```

## WireGuard secret and deployment

`CFMESH_CONFIG` is a required Fly secret containing the complete, multiline
`wg-quick` configuration. Startup writes it to
`/etc/wireguard/cfmesh.conf` with mode `0600` in a `0700` directory,
removes it from the environment, and runs `wg-quick up cfmesh`.
Missing secrets or tunnel setup failures stop startup before HTTP is served.

Keep the source config outside the build directory. Set the secret from
your existing config, then deploy:

```sh
fly apps create "$FLY_APP"
fly volumes create soju_data --app "$FLY_APP" --region iad --size 1
fly secrets set --app "$FLY_APP" --stage CFMESH_CONFIG="$(cat /path/to/cfmesh.conf)"
fly deploy --app "$FLY_APP" --ha=false
```

For an existing app, create the volume once with the command above, then
redeploy to attach it at `/data`. Keep the app on one machine so it uses
that volume.

Fly injects secrets as environment variables at boot; see
[Fly secrets](https://fly.io/docs/apps/secrets/).
The config must supply this machine's private key, addresses, and peers.
The runtime needs kernel WireGuard support and permission to create network
interfaces; local container runs need `--cap-add NET_ADMIN`.
`openresolv` supports a config's `DNS` setting, and `iptables` supports
`wg-quick` default-route handling.

## Move the existing database

The same path does not copy data between Northflank and Fly. Before the
first soju deployment, transfer a consistent database export to the Fly
volume while Fly is still running the lighttpd-only image. Do not replace
the database while Fly soju is running.

On the Northflank container, create a consistent export (including WAL data):

```sh
sqlite3 /data/soju/main.db ".backup '/tmp/main.db'"
```

Download that export to your workstation, stop the old Northflank service
for the final cutover, and upload the final export to Fly:

```sh
fly ssh console --app "$FLY_APP" -C 'mkdir -p /data/soju'
fly ssh sftp put --app "$FLY_APP" --mode 0600 ./main.db /data/soju/main.db
fly deploy --app "$FLY_APP" --ha=false
```

Make the final export after stopping writes on the source so changes made
after an earlier export are not lost. Startup fixes ownership for the
`soju` account (UID/GID 1000). The Northflank configuration is unchanged.

## soju settings

The bundled config uses `message-store db`, five-day message expiry, and
a 200-message CHATHISTORY limit, matching soju-nf. Startup waits for the
admin socket before serving gamja and supervises soju and lighttpd.

| Variable | Default | Purpose |
| --- | --- | --- |
| `SOJU_CONFIG_FILE` | `/usr/share/soju/config` | Optional replacement config copied to `/etc/soju/config` |
| `SOJU_DATA_DIR` | `/data/soju` | Permissions path; custom configs must use the corresponding DB path |
| `SOJU_STARTUP_TIMEOUT` | `1800` | Admin socket startup timeout in seconds; `0` waits indefinitely |
| `SOJU_ADMIN_USER` | `admin` | Bootstrap admin username |
| `SOJU_ADMIN_PASSWORD` | unset | Creates an admin if absent; existing admin passwords are preserved |
| `GAMJA_DATA_DIR` | `/data/gamja` | Persistent gamja installation |
| `GAMJA_CONFIG_JSON` | mandatory auth, ping 30s | Gamja settings served at `/config.json` |
| `TZ` | `UTC` | Service time zone |

For a fresh database, set the initial password before deployment:

```sh
fly secrets set --app "$FLY_APP" --stage SOJU_ADMIN_PASSWORD='<strong password>'
```

With an imported database, use its existing credentials. Admin commands
use `/etc/soju/config` automatically:

```sh
fly ssh console --app "$FLY_APP" -C 'su-exec soju sojuctl user status admin'
```

Update gamja without rebuilding by running `/data/update-gamja.sh` inside
the machine. The next image deployment preserves the installed gamja.

## Verify

```sh
fly logs
fly checks list
fly ssh console -C 'wg show cfmesh'
fly proxy 8080:8080
```

With the proxy running, open `http://localhost:8080/` and
`http://localhost:8080/healthz`; the test page is at `/test.html`. From a peer with the appropriate routes,
use `http://<cfmesh-address>:8080/` directly. Keep exactly one machine
with `fly scale count 1`.
