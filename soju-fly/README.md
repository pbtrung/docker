# soju + gamja + nginx on Fly.io

The [soju-nf](../soju-nf) image adapted for [Fly.io]. It runs:

- [soju-rs] — Rust port of the [soju] IRC bouncer, static musl binaries
  from the latest [pbtrung/soju-rs release][soju-rs releases]
- [gamja] — IRC web client, prebuilt release from the [pbtrung/gamja] fork,
  kept on the volume so it can be updated from a shell
- nginx, one worker — serves gamja and proxies the IRC WebSocket
  (`/socket`) to soju, on plain HTTP port 8080
- a [Twingate connector] — the only way in from outside: it only makes
  outbound connections to Twingate, so the app has no public port

The app has no `[[services]]`, so the Fly proxy routes nothing to the
machine. gamja and soju's IRC port are reached as Twingate resources, from
devices running the Twingate client, or over Fly's private network.

File uploads (IRCv3 filehost) are disabled: soju-rs doesn't support them
and nginx doesn't proxy `/uploads`.

```
browser ─Twingate─▶ connector (same machine) ─▶ nginx :8080 ─┬─ /            gamja static files
                                                             ├─ /config.json  gamja config
                                                             ├─ /socket       ─▶ soju 127.0.0.1:8081 (WebSocket)
                                                             └─ /healthz      200 ok
IRC client ─Twingate─▶ connector ─▶ soju :6667 plain IRC
Fly health check ──▶ nginx :8080
```

Ports 8080 and 6667 also listen on Fly's private network (6PN), e.g.
`$FLY_APP.internal:6667`, which `fly proxy` and `fly wireguard` can reach.

Fly settings (`fly.toml`): app from `$FLY_APP` (see [App name](#app-name)), region `iad`, one
`shared-cpu-1x` machine with 256 MB, no public service, and a 1 GB volume
`soju_data` at `/data`. It holds:

```
/data/
├── soju/main.db                 SQLite DB (SOJU_DATA_DIR)
├── gamja/                       gamja web client (GAMJA_DATA_DIR)
└── update-gamja.sh              gamja updater, copied on every start
```

## Files

| File              | Purpose |
| ----------------- | ------- |
| `fly.toml`        | Fly app config: no public service, `/healthz` check, volume, VM size |
| `Dockerfile`      | `builder` stage downloads a soju-rs release (checked against its `SHA256SUMS`) and a gamja release, and copies the Twingate connector (with its glibc libraries) from `twingate/connector:1`; runtime stage on alpine:edge installs nginx, rclone and sqlite with `apk` |
| `soju.conf`       | soju config, installed as `/etc/soju/config`: DB, message expiry, `chathistory-limit`, listeners, hostname |
| `soju-wrapper.sh` | Installed as `soju` and `sojuctl`: runs the soju-rs binary with `-config /etc/soju/config` |
| `entrypoint.sh`   | Installs gamja on the volume, uses `SOJU_CONFIG_FILE` as the soju config if set, creates the first admin, starts the Twingate connector, nginx, then soju |
| `update-gamja.sh` | Installs a gamja release (latest, or a given tag) into `GAMJA_DATA_DIR` |
| `nginx.conf`      | One worker; plain HTTP server on 8080, per-IP limits |
| `gamja-locations.conf` | gamja, `/config.json`, `/socket` and `/healthz` locations |

## Environment variables

Set plain values under `[env]` in `fly.toml`, and secrets with
`fly secrets set`.

| Variable              | Default                                     | Description |
| --------------------- | ------------------------------------------- | ----------- |
| `TWINGATE_NETWORK`    | —                                           | Twingate network name (the `<network>` of `<network>.twingate.com`). **Secret** |
| `TWINGATE_ACCESS_TOKEN` | —                                         | Connector access token. **Secret** |
| `TWINGATE_REFRESH_TOKEN` | —                                        | Connector refresh token. **Secret**. The connector only starts when all three are set; the tokens are removed from the environment before nginx and soju start |
| `TWINGATE_RESOURCE_IP` | `100.120.10.1`                           | Private IPv4 added to the machine's loopback: the Twingate Resource address |
| `SOJU_ADMIN_USER`     | —                                           | Admin user created on first start (only while `/data/soju/main.db` doesn't exist) |
| `SOJU_ADMIN_PASSWORD` | —                                           | Password for that admin user. **Secret** |
| `SOJU_CONFIG_FILE`    | —                                           | Path to a complete soju config to use instead of the bundled `soju.conf` |
| `GAMJA_CONFIG_JSON`   | `{"server":{"auth":"mandatory","ping":30}}` | gamja [config file] contents, served at `/config.json` |
| `SOJU_DATA_DIR`       | `/data/soju`                                | Where the soju DB (`main.db`) is stored. Must match the `db` path of the soju config |
| `GAMJA_DATA_DIR`      | `/data/gamja`                               | Where gamja is installed; `update-gamja.sh` is copied to its parent directory |

Build arguments: `SOJU_REF` (default `latest`) selects the
[soju-rs release][soju-rs releases] to install (e.g. `v0.99.2`).
`GAMJA_REF` (default `latest`) selects the gamja release
bundled in the image, only installed on a volume without gamja.

The release metadata (GitHub's latest soju-rs and gamja releases) is fetched with `ADD` on every build, so a new release
invalidates the cached download layers: "latest" really is the latest, even
with the build cache. The startup log shows the soju-rs version running
(`Starting soju-rs vX`).

## Deploy

Run these from this directory (`soju-fly/`), logged in with `fly auth login`.

### App name

The app name is part of its `<app>.fly.dev` hostname and `<app>.internal`
address, so it's kept out of the repo: `fly.toml` has no `app`, and flyctl
reads the `FLY_APP` environment variable instead. Keep it in `.env`
(ignored by git and Docker), with the Twingate values: `soju` and 38
random lowercase letters and digits, 42 characters in all:

```sh
printf 'FLY_APP=soju%s\n' "$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 38)" > .env
```

Load it in each shell before running `fly` commands:

```sh
export $(cat .env)            # fish, or bash/zsh
```

Without `FLY_APP`, `fly deploy` stops with an error rather than deploying
somewhere else.

### Twingate

In the Twingate admin console:

1. Add a Remote Network (e.g. `fly`), then a connector in it: choose
   Docker and generate tokens. Put them in `.env` with the network name:

   ```
   TWINGATE_NETWORK=<network>         # <network>.twingate.com
   TWINGATE_ACCESS_TOKEN=...
   TWINGATE_REFRESH_TOKEN=...
   ```

2. Add a Resource in that Remote Network with the address `100.120.10.1`
   (`TWINGATE_RESOURCE_IP`) and ports `8080` (gamja) and `6667` (IRC), and
   give your group access to it.

Twingate Resources must be IPv4, and `<FLY_APP>.internal` only has an IPv6
(6PN) address: as a Resource, the client resolves it but the connector
can't connect, and browsers get an empty reply. The connector runs on the
soju machine, so `entrypoint.sh` adds `TWINGATE_RESOURCE_IP` to its
loopback interface; nginx (`0.0.0.0:8080`) and soju (`[::]:6667`)
answer on it. `127.0.0.1` can't be the Resource: the client device would
answer it itself. `100.120.10.1` is in the carrier-grade NAT range
(`100.64.0.0/10`) but outside `100.96.0.0/12`, where the Twingate client
puts the addresses it gives DNS Resources, and `100.95.0.x`, its DNS
servers. To change it, set `TWINGATE_RESOURCE_IP` and the Resource
together.

From a device running the Twingate client, gamja is at
`http://100.120.10.1:8080` and IRC at `100.120.10.1:6667` (plain IRC;
Twingate encrypts the tunnel). An IP Resource needs no DNS, so it works
with browsers' secure DNS (DoH). `entrypoint.sh` also maps
`soju.internal` to the address in `/etc/hosts`, which the connector reads
(glibc, with `hosts: files dns` in `/etc/nsswitch.conf`): a Resource
`soju.internal` works too, but only for apps that use the system resolver,
not a browser with secure DNS on.

### Deploy

```sh
# 1. App and volume
fly apps create "$FLY_APP"
fly volumes create soju_data --region iad --size 1

# 2. Secrets
fly secrets set --stage \
  SOJU_ADMIN_USER=admin \
  SOJU_ADMIN_PASSWORD='<a strong password>'
grep '^TWINGATE_' .env | fly secrets import --stage

# 3. Build and deploy a single machine
fly deploy --ha=false
```

`--stage` stores the secrets without restarting anything; the first deploy
picks them up.

With no service, the app needs no IP address: `fly deploy` doesn't
allocate one, and an existing one routes nothing. To drop the old
dedicated IPv6, `fly ips list` and `fly ips release <address>`; a shared
IPv4 can stay.

The startup log shows `Starting the Twingate connector for network ...`,
then the connector's `State: Online`; the connector also shows as
connected in the admin console. `fly ssh console -C 'connectorctl health'`
checks it from the machine.

Keep a single machine: the volume can only attach to one, and soju
can't run as several instances. To check, run `fly scale show`. If
there are more, run `fly scale count 1`. With no service, the Fly proxy
never stops, starts or creates machines, and `[[restart]] policy = 'always'`
restarts the machine if soju exits.

The connector binaries in the `twingate/connector:1` image are linked
against glibc, which Alpine doesn't have: the build copies them with the
glibc libraries from the same image into `/opt/twingate`, and patches
their ELF interpreter and RPATH to load only those. Each `fly deploy`
picks up the latest `1.x` connector.

The image build runs on Fly's remote builder and only installs packages and
downloads releases.

### Log in

With the Twingate client connected, open `http://100.120.10.1:8080`.
gamja loads. Log in with
`SOJU_ADMIN_USER` / `SOJU_ADMIN_PASSWORD`, then add an upstream network,
either in gamja's "add network" UI or with `BouncerServ`:

```
/msg BouncerServ network create -addr ircs://irc.libera.chat -name libera -nick yournick
/msg BouncerServ sasl set-plain -network libera yournick <nickserv-password>
```

`/msg BouncerServ help` lists every command. After the first start you can
remove the admin password: `fly secrets unset SOJU_ADMIN_PASSWORD`.

### Manage users

From gamja as an admin (`/msg BouncerServ user create -username bob -password <password>`),
or from a shell on the machine:

```sh
fly ssh console
sojuctl user create -username bob -password <password>
sojuctl user status
```

`sojuctl` already knows where the config is (`/etc/soju/config`). soju-rs
has no `sojudb`: the entrypoint creates the first admin with `sojuctl` over
the admin socket once soju is up.

## Updating

- `fly deploy` rebuilds the image and picks up the latest soju-rs release
  (check `Starting soju-rs vX` in `fly logs`). The DB lives on the
  volume and survives it. soju migrates its schema itself on startup.
- gamja is updated from a shell, not by a new image:

  ```sh
  fly ssh console -C /data/update-gamja.sh            # latest release
  fly ssh console -C '/data/update-gamja.sh v0.999.0' # a specific tag
  ```

  The script downloads the release's `.zip`, unpacks it next to the current
  copy and swaps the two directories, so nginx never serves a half-installed
  tree. Set `FORCE=1` to reinstall the same tag. Reload gamja in the browser
  afterwards. No restart is needed.

## Backups

Fly takes daily snapshots of the volume (`fly volumes snapshots list <volume-id>`).
To copy the DB out, first take a consistent copy with the `sqlite3` CLI
(soju keeps writing to `main.db` and its `-wal` file while it runs):

```sh
fly ssh console -C "sqlite3 /data/soju/main.db '.backup /tmp/main.db'"
fly ssh sftp get /tmp/main.db main.db
```

`sqlite3` also lets you inspect the DB from a shell, e.g.
`sqlite3 -readonly /data/soju/main.db '.tables'`.

## Message expiry

soju deletes messages older than `message-expiry` in `soju.conf` (5 days)
on startup and then daily, and vacuums the DB to give the space back to the
volume.

## History limit

`chathistory-limit 200` in `soju.conf` caps each CHATHISTORY reply at 200
messages: gamja loads the latest 200 lines of each buffer on connect (its
default), and fetches older or missed messages in more requests. This keeps
soju's memory down on the 256 MB machine while gamja loads every buffer.

## Run locally

```sh
docker build -t soju-fly soju-fly/
docker run --rm -p 8080:8080 -v soju-data:/data \
  -e SOJU_ADMIN_USER=admin -e SOJU_ADMIN_PASSWORD=changeme \
  soju-fly
```

gamja is then at `http://localhost:8080`. Without the `TWINGATE_*`
variables, the connector stays off.

## Notes

- Through Twingate, nginx sees every client at the connector's address, so
  the per-IP limits apply to all Twingate users together: 60 requests per
  minute for gamja's files (burst 30) and 20 concurrent connections; nginx
  closes the connection on a violation. soju also sees that address as
  every client's host (`X-Forwarded-For`, trusted from loopback with
  `accept-proxy-ip localhost`). Any `Forwarded` header from a client is
  dropped, since soju prefers it.
- Nothing listens publicly: there's no service for the Fly proxy to route,
  and the connector only connects out. Twingate checks who may reach the
  resource before any traffic gets to nginx or soju.
- gamja sends `PING` every 30 s by default (`GAMJA_CONFIG_JSON`) to keep
  its WebSocket open through NAT and proxies.
- The connector runs as the `twingate` user, restarted 5 s after it exits;
  soju stays the main process, so a connector crash doesn't stop the
  bouncer.
- The machine never stops on its own, and `[[restart]] policy = 'always'`
  restarts it if soju exits. Deploys stop it and start the new image on the
  same volume (`strategy = 'immediate'`), sending soju `SIGTERM` with 30 s
  to shut down cleanly. 512 MB of swap keeps a memory spike from
  OOM-killing soju on the 256 MB VM, now shared with the connector.

[Fly.io]: https://fly.io/
[soju]: https://soju.im/
[soju-rs]: https://github.com/pbtrung/soju-rs
[soju-rs releases]: https://github.com/pbtrung/soju-rs/releases
[gamja]: https://codeberg.org/emersion/gamja
[pbtrung/gamja]: https://github.com/pbtrung/gamja
[Twingate connector]: https://www.twingate.com/docs/connectors
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
