# soju + gamja + nginx on Northflank, behind Twingate

A single container image for [Northflank] that runs:

- [soju-rs] — Rust port of the [soju] IRC bouncer, static musl binaries
  from the latest [pbtrung/soju-rs release][soju-rs releases], as in
  [soju-fly](../soju-fly)
- [gamja] — IRC web client, prebuilt release from the [pbtrung/gamja] fork,
  kept on the volume so it can be updated from a shell
- nginx — serves gamja and proxies the IRC WebSocket (`/socket`) to soju,
  on plain HTTP port 8080
- a [Twingate connector] — the only way in from outside: it only makes
  outbound connections to Twingate, so no port is public

File uploads (IRCv3 filehost) are disabled: soju-rs doesn't support them
and nginx doesn't proxy `/uploads`.

```
browser ─Twingate─▶ connector (same container) ─▶ soju.internal:8080 nginx ─┬─ /            gamja static files
                                                                            ├─ /config.json  gamja config
                                                                            ├─ /socket       ─▶ soju 127.0.0.1:8081 (WebSocket)
                                                                            └─ /healthz      200 ok
IRC client ─Twingate─▶ connector ─▶ soju.internal:6667 soju plain IRC
Northflank health check ──▶ nginx :8080
```

`/data` should be a Northflank volume. It holds:

```
/data/
├── soju/main.db      SQLite DB (SOJU_DATA_DIR)
├── gamja/           gamja web client (GAMJA_DATA_DIR)
├── rclone.conf      rclone config for the daily DB backup (you add it)
└── update-gamja.sh  gamja updater, copied on every start
```

## Existing database

An existing `/data/soju/main.db`, e.g. from the Go soju of the Alpine
package this image used before, is used as is: its users and networks
stay, and `SOJU_ADMIN_USER` is only created on an empty volume. soju-rs
migrates its schema on startup. On every start, `entrypoint.sh` chowns
`/data/soju` and everything in it (`main.db`, `-wal`, `-shm`) to the `soju`
user, uid/gid 1000 like the Alpine package's, and makes it private to it
(`u+rwX,go-rwx`): soju needs to write the directory for the `-wal` and
`-shm` files, and the DB holds password hashes and network secrets. A DB
copied in as root, or world-readable, works and is locked down.

`soju.conf` sets `message-expiry 5d`, as in soju-fly: soju-rs deletes
messages older than 5 days on startup, then daily. On an existing DB with a
longer history, that happens on the first start. Use `0d` in a
`SOJU_CONFIG_FILE` to keep everything.

## Daily backup

`backup-soju.sh` copies the DB to object storage with rclone, daily at
03:00 UTC (`SOJU_BACKUP_CRON`), run by BusyBox `crond`:

```sh
rclone --config /data/rclone.conf copy <snapshot>/main.db tigris:skypiea/soju/
```

soju keeps writing to `main.db` and its `-wal` file while it runs, so the
script first takes a consistent snapshot with `sqlite3 .backup`, and
uploads that, still named `main.db`. Each backup replaces the previous one;
use bucket versioning to keep older copies.

Put the rclone config, with a `tigris` remote, on the volume as
`/data/rclone.conf` (the entrypoint makes it root-only, mode 600). Without
it, the job logs `rclone.conf doesn't exist, skipping the backup`. Its
output, and crond's `USER root pid … cmd` lines, are in the container logs.
Run it by hand from a shell with `backup-soju.sh`.

## Files

| File            | Purpose |
| --------------- | ------- |
| `Dockerfile`    | `builder` stage (alpine:edge) downloads a soju-rs release (checked against its `SHA256SUMS`) and a gamja release, and copies the Twingate connector (with its glibc libraries) from `twingate/connector:1`; runtime stage on alpine:edge installs nginx, rclone and sqlite with `apk` |
| `soju.conf`     | soju config, installed as `/etc/soju/config`: DB, message expiry, `chathistory-limit`, listeners, hostname |
| `soju-wrapper.sh` | Installed as `soju` and `sojuctl`: runs the soju-rs binary with `-config /etc/soju/config` |
| `entrypoint.sh` | Fixes the soju data's ownership, installs gamja on the volume, creates the first admin on an empty volume, schedules the daily backup, maps `TWINGATE_RESOURCE_HOST` to the container's address, starts the Twingate connector, nginx, then soju |
| `backup-soju.sh` | Uploads a consistent snapshot of the soju DB with rclone; run daily by crond |
| `update-gamja.sh` | Installs a gamja release (latest, or a given tag) into `GAMJA_DATA_DIR` (`/data/gamja`) |
| `nginx.conf`    | Serves gamja, `/config.json` and `/healthz`, proxies `/socket` to soju, per-IP limits |

## Environment variables

| Variable                 | Default                                     | Description |
| ------------------------ | ------------------------------------------- | ----------- |
| `TWINGATE_NETWORK`       | —                                           | Twingate network name (the `<network>` of `<network>.twingate.com`) |
| `TWINGATE_ACCESS_TOKEN`  | —                                           | Connector access token. **Secret** |
| `TWINGATE_REFRESH_TOKEN` | —                                           | Connector refresh token. **Secret**. The connector only starts when all three are set; the tokens are removed from the environment before nginx and soju start |
| `TWINGATE_RESOURCE_HOST` | `soju.internal`                             | Name of the Twingate Resource: mapped to the container's own IPv4 address in `/etc/hosts` on every start |
| `SOJU_ADMIN_USER`        | —                                           | Admin user created on first start, only while `/data/soju/main.db` doesn't exist |
| `SOJU_ADMIN_PASSWORD`    | —                                           | Password for that admin user. **Secret** |
| `SOJU_CONFIG_FILE`       | —                                           | Path to a complete soju config to use instead of the bundled `soju.conf` |
| `SOJU_DATA_DIR`          | `/data/soju`                                | Where the soju DB (`main.db`) is stored. Must match the `db` path of the soju config |
| `SOJU_BACKUP_CRON`       | `0 3 * * *`                                 | When to run the DB backup (crontab schedule, UTC) |
| `SOJU_BACKUP_REMOTE`     | `tigris:skypiea/soju/`                      | rclone destination of the DB backup |
| `RCLONE_CONFIG_FILE`     | `/data/rclone.conf`                         | rclone config used by the DB backup |
| `GAMJA_CONFIG_JSON`      | `{"server":{"auth":"mandatory","ping":30}}` | gamja [config file] contents, served at `/config.json` |
| `GAMJA_DATA_DIR`         | `/data/gamja`                               | Where gamja is installed; `update-gamja.sh` is copied to its parent directory |

Build arguments: `SOJU_REF` (default `latest`) selects the
[soju-rs release][soju-rs releases] to install (e.g. `v0.99.17`).
`GAMJA_REF` (default `latest`) selects the gamja release tag bundled in the
image. It's only installed on a volume that doesn't have gamja yet.

## Twingate

### Why a name, not an IP

On Fly.io the Resource is a fixed IP added to loopback. A Northflank
container can't do that (no `NET_ADMIN`), and its own address changes with
every restart. So the Resource is a name, `TWINGATE_RESOURCE_HOST`
(`soju.internal`): on every start, `entrypoint.sh` maps it to the
container's IPv4 address in `/etc/hosts`, which the connector reads (glibc,
with `hosts: files dns` in `/etc/nsswitch.conf`). nginx listens on all
addresses. The startup log shows `Twingate Resource soju.internal is <ip>`.

### Set up

In the Twingate admin console:

1. Add a Remote Network (e.g. `northflank`) and a connector in it; choose
   Docker and generate tokens. Use a Remote Network of its own: its
   connector can only reach this container.
2. Add a Resource in that Remote Network with the address `soju.internal`
   and ports `8080` (gamja) and `6667` (IRC), and give your group access
   to it.

Each Resource name can only be used once across Remote Networks: if another
one already has a `soju.internal` Resource, set `TWINGATE_RESOURCE_HOST`
to another name here.

From a device running the Twingate client, gamja is at
`http://soju.internal:8080` and IRC at `soju.internal:6667` (plain IRC;
Twingate encrypts the tunnel). The browser must resolve the name through the
system resolver, i.e. the Twingate client: turn off its own secure DNS (DoH),
or it gets `DNS_PROBE_FINISHED_NXDOMAIN`. Twingate's Secure DNS keeps the
lookups encrypted.

## Deploy on Northflank (web UI)

### 1. Push this repo to a Git provider

Push this repository to GitHub, GitLab or Bitbucket. In Northflank, open
**Account / Team settings → Git integrations** and connect that provider.
Give Northflank access to the repository.

### 2. Create a project

**Create new → Project**. Pick a name (e.g. `irc`) and a region close to you.

### 3. Create a combined service

Inside the project: **Create new → Service → Combined service** (this builds
from Git and deploys in one service).

- **Name:** `soju`
- **Repository:** this repo, branch `main`
- **Build type:** `Dockerfile`
  - **Dockerfile location:** `/soju-nf/Dockerfile`
  - **Build context:** `/soju-nf`
  - (optional) **Build arguments:** `GAMJA_REF` to pin a gamja release
    tag instead of the latest
- **Resources:** the smallest compute plan is enough. **Instances: 1**: a
  second instance would run a second connector with the same tokens.

### 4. Networking

Northflank reads `EXPOSE` from the Dockerfile and adds ports 8080 (HTTP)
and 6667 (TCP). Keep both **private**: turn off **Publicly expose this port
to the internet**. Twingate reaches them from inside the container, and the
health check doesn't need them public either.

### 5. Environment variables

Under **Environment variables** (runtime), add the Twingate values, as
**secrets** for the tokens:

```
TWINGATE_NETWORK=<network>
TWINGATE_ACCESS_TOKEN=<access token>
TWINGATE_REFRESH_TOKEN=<refresh token>
```

On a new, empty volume, also add the first admin (skip it to keep using an
existing DB):

```
SOJU_ADMIN_USER=admin
SOJU_ADMIN_PASSWORD=<a strong password>
```

Click **Create service**. The startup log shows
`Starting the Twingate connector for network <network>`, then the
connector's `State: Online`; the connector also shows as connected in the
admin console.

### 6. Add a persistent volume

Without a volume, every redeploy wipes the database and all users. To keep
an existing one, attach the volume that holds `/data/soju/main.db` (see
[Existing database](#existing-database)).

Open the service → **Volumes → Add volume** (or attach the existing one):

- **Name:** `soju-data`
- **Size:** 1 GB is plenty
- **Mount path:** `/data`

### 7. Health check (recommended)

Service → **Health checks → Add health check**:

- **Protocol:** HTTP, **Port:** 8080, **Path:** `/healthz`
- Type: readiness and/or liveness. Liveness restarts the container if
  nginx stops answering.

### 8. Log in

With the Twingate client connected, open `http://soju.internal:8080`.
gamja loads. Log in with an existing user, or `SOJU_ADMIN_USER` /
`SOJU_ADMIN_PASSWORD` on a new volume, then add an upstream network, either
in gamja's "add network" UI or with `BouncerServ`:

```
/msg BouncerServ network create -addr ircs://irc.libera.chat -name libera -nick yournick
/msg BouncerServ sasl set-plain -network libera yournick <nickserv-password>
```

`/msg BouncerServ help` lists every command. After the first start you can
remove `SOJU_ADMIN_PASSWORD`.

### 9. Manage users

From gamja as an admin
(`/msg BouncerServ user create -username bob -password <password>`), or
from a shell on the container (service → **Containers** → **Shell**):

```sh
sojuctl user create -username bob -password <password>
sojuctl user status
```

`sojuctl` already knows where the config is (`/etc/soju/config`). soju-rs
has no `sojudb`: the entrypoint creates the first admin with `sojuctl` over
the admin socket once soju is up.

### Backups

See [Daily backup](#daily-backup). Northflank can also take volume
backups.

### Updating

- Pushing to `main` triggers a rebuild and redeploy automatically, which
  also picks up the latest soju-rs release and `1.x` Twingate connector.
  The DB lives on the volume and survives it; soju migrates its schema
  itself on startup.
- gamja is updated from a shell instead (see
  [Updating gamja](#updating-gamja)). A new image doesn't replace the copy
  on the volume.

## Updating gamja

gamja is served from `/data/gamja`. On the first start the entrypoint copies
the release bundled in the image there, and on every start it copies
`update-gamja.sh` to `/data`. To switch to another release of
[pbtrung/gamja] without a new image, open a shell on the container
(service → **Containers** → **Shell**) and run:

```sh
/data/update-gamja.sh           # latest release
/data/update-gamja.sh v0.999.0  # a specific release tag
FORCE=1 /data/update-gamja.sh   # reinstall even if already installed
```

It downloads the release's `.zip` asset (gamja's `dist/`, with `index.html`
at the root or in one top-level folder), unpacks it next to the current copy and
swaps the two directories, so nginx never serves a half-installed tree. The
installed tag is in `/data/gamja/.version`. Reload gamja in the browser
afterwards. No restart is needed.

## Run locally

```sh
docker build -t soju-nf soju-nf/
docker run --rm -p 8080:8080 -p 6667:6667 -v soju-nf-data:/data \
  -e SOJU_ADMIN_USER=admin -e SOJU_ADMIN_PASSWORD=changeme \
  soju-nf
```

Then open http://localhost:8080. Without the `TWINGATE_*` variables, the
connector stays off.

## Notes

- Through Twingate, nginx sees every client at the connector's address, so
  the per-IP limits apply to all Twingate users together: 60 requests per
  minute for gamja's files (burst 30) and 20 concurrent connections. soju
  also sees that address as every client's host (`X-Forwarded-For`,
  trusted from loopback with `accept-proxy-ip localhost`). Any `Forwarded`
  header from a client is dropped, since soju prefers it.
- The connector runs as the `twingate` user, restarted 5 s after it exits.
  soju is the main process: if it exits, the container stops and
  Northflank restarts it.
- gamja sends `PING` every 30 s by default (`GAMJA_CONFIG_JSON`) to keep
  its WebSocket open.
- `connectorctl health` in a shell on the container checks the connector.

[Northflank]: https://northflank.com/
[gamja]: https://codeberg.org/emersion/gamja
[pbtrung/gamja]: https://github.com/pbtrung/gamja
[Twingate connector]: https://www.twingate.com/docs/connectors
[soju]: https://soju.im/
[soju-rs]: https://github.com/pbtrung/soju-rs
[soju-rs releases]: https://github.com/pbtrung/soju-rs/releases
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
