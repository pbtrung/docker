# soju + gamja + nginx on Northflank, behind Twingate

A single container image for [Northflank] that runs:

- the soju C port — a C port of the [soju] IRC bouncer, behaviorally
  matched to [soju-rs] (the Rust port): built from source from the
  `c-port` branch of [pbtrung/soju-rs][soju-rs] (amd64 only)
- [gamja] — IRC web client, prebuilt release from the [pbtrung/gamja] fork,
  kept on the volume so it can be updated from a shell
- nginx — serves gamja and proxies the IRC WebSocket (`/socket`) to soju,
  on plain HTTP port 8080
- a [Twingate connector] — the only way in from outside: it only makes
  outbound connections to Twingate, so no port is public
- a daily backup of the soju database to an rclone remote (BusyBox `crond`)

File uploads (IRCv3 filehost) are disabled: soju doesn't support them
and nginx doesn't proxy `/uploads`.

```
browser ─Twingate─▶ connector (same container) ─▶ soju.internal:8080 nginx ─┬─ /            gamja static files
                                                                            ├─ /config.json  gamja config
                                                                            ├─ /socket       ─▶ soju 127.0.0.1:8081 (WebSocket)
                                                                            └─ /healthz      200 ok
IRC client ─Twingate─▶ connector ─▶ soju.internal:6667 soju plain IRC
Northflank health check ──▶ nginx :8080
```

## Storage

Accounts, networks and messages live in a local SQLite database,
`/data/soju/main.db` (`db sqlite3` and `message-store db`), on a persistent
volume mounted at `/data`:

```text
/data/
├── soju/main.db     soju database, with its -wal and -shm files (SOJU_DATA_DIR)
├── rclone.conf      rclone remotes for the backup (RCLONE_CONFIG_FILE), optional
├── gamja/           gamja web client (GAMJA_DATA_DIR)
└── update-gamja.sh  gamja updater, copied on every start
```

On every start, the entrypoint makes `/data/soju` readable only by `soju`
(the database holds password hashes and network secrets). An existing
`main.db` is reused: soju migrates older schemas, including databases of
upstream Go soju, on startup.

`soju.conf` sets `message-expiry 5d`: messages older than five days are
deleted at startup and daily. soju vacuums the database on startup,
before clients can connect, and when a configuration reload changes
`message-expiry`. Set `message-expiry 0d` in a custom config
(`SOJU_CONFIG_FILE`) to keep messages forever.

### Upgrading to schema 35

The C port uses the database of soju-rs v0.99.24, schema 35, and migrates
older databases (soju-rs or upstream Go soju) on startup. In schema 35 the
message table is clustered by conversation and time, which cuts the disk
reads (and the memory spike) when a client loads history, and conversations
record their latest mention for gamja's unread and mention badges. Older
soju versions can't open the upgraded database: take a backup first
(`backup-soju.sh`, below). The one-time copy of the message table needs
free space on the volume up to about twice its size. The entrypoint waits
up to `SOJU_STARTUP_TIMEOUT` seconds (default 1800, or 0 for unlimited) for
soju to finish migrating, while still detecting an exited soju process.

### Bootstrap admin

When `SOJU_ADMIN_PASSWORD` is set, startup checks `SOJU_ADMIN_USER`
(default `admin`) through the admin socket. A missing account is created
as an admin. An existing admin keeps its stored password. An existing
non-admin account, or an account lookup or creation failure, stops the
container. Remove `SOJU_ADMIN_PASSWORD` after setup: changing it doesn't
reset an existing password.

### Backups

`backup-soju.sh` takes a consistent snapshot of `main.db` with
`sqlite3 .backup` (soju keeps writing to it and its `-wal` file, so the
file itself could be torn) and copies it to `SOJU_BACKUP_REMOTE` with
rclone, still named `main.db`. BusyBox `crond` runs it daily, at 03:00 by
default (`SOJU_BACKUP_CRON`); its output goes to the container log. Run it
from a shell for an immediate backup:

```sh
backup-soju.sh
```

Put the rclone remotes in `/data/rclone.conf` (owned by root, mode 600 on
every start): without it, the job logs that it skips the backup. For
example, for an S3-compatible bucket:

```ini
[tigris]
type = s3
provider = Other
access_key_id = <key>
secret_access_key = <secret>
endpoint = https://fly.storage.tigris.dev
```

To restore, stop the service, put the backup at `/data/soju/main.db`
(removing any `main.db-wal` and `main.db-shm` next to it), and start it
again.

## Files

| File            | Purpose |
| --------------- | ------- |
| `Dockerfile`    | `soju-builder` compiles the soju C port from the `c-port` branch; `builder` downloads a gamja release and copies the Twingate connector (with its glibc libraries) from `twingate/connector`; runtime stage on alpine:edge installs nginx, su-exec, rclone, sqlite and soju's shared libraries with `apk` |
| `soju.conf`     | Base config installed at `/usr/share/soju/config`: SQLite storage, message expiry, `chathistory-limit`, listeners, hostname |
| `soju-wrapper.sh` | Installed as `soju` and `sojuctl`: runs the soju binary with `-config /etc/soju/config` |
| `entrypoint.sh` | Installs the config and gamja, schedules the backup, starts the connector and soju, bootstraps the admin, then starts nginx; forwards shutdown to soju |
| `backup-soju.sh` | Snapshots `main.db` and copies it with rclone (daily via crond, or by hand) |
| `update-gamja.sh` | Installs a gamja release (latest, or a given tag) into `GAMJA_DATA_DIR` (`/data/gamja`) |
| `nginx.conf`    | Serves gamja, `/config.json` and `/healthz`, proxies `/socket` to soju, per-IP limits |

## Environment variables

| Variable                 | Default                                     | Description |
| ------------------------ | ------------------------------------------- | ----------- |
| `TWINGATE_NETWORK`       | —                                           | Twingate network name (the `<network>` of `<network>.twingate.com`) |
| `TWINGATE_ACCESS_TOKEN`  | —                                           | Connector access token. **Secret** |
| `TWINGATE_REFRESH_TOKEN` | —                                           | Connector refresh token. **Secret**. The connector only starts when all three are set; the tokens are removed from the environment before nginx and soju start |
| `TWINGATE_RESOURCE_HOST` | `soju.internal`                             | Name of the Twingate Resource: mapped to the container's own IPv4 address in `/etc/hosts` on every start |
| `SOJU_ADMIN_USER`        | `admin`                                     | Bootstrap admin username, checked when `SOJU_ADMIN_PASSWORD` is set |
| `SOJU_ADMIN_PASSWORD`    | —                                           | Initial password for a missing bootstrap admin. **Secret**; existing passwords are kept |
| `SOJU_STARTUP_TIMEOUT`   | `1800`                                      | Seconds to wait for migrations and startup maintenance (admin socket); `0` disables the deadline |
| `SOJU_CONFIG_FILE`       | —                                           | Path to a soju config to use instead of the bundled `soju.conf`; keep the admin listener at `/run/soju/admin` |
| `SOJU_DATA_DIR`          | `/data/soju`                                | Directory of `main.db`; a custom config must point `db` there |
| `SOJU_BACKUP_CRON`       | `0 3 * * *`                                 | crond schedule of `backup-soju.sh` (container time zone, UTC by default) |
| `SOJU_BACKUP_REMOTE`     | `tigris:skypiea/soju/`                      | rclone destination of the backup |
| `RCLONE_CONFIG_FILE`     | `/data/rclone.conf`                         | rclone config with the remote's credentials |
| `GAMJA_CONFIG_JSON`      | `{"server":{"auth":"mandatory","ping":30}}` | gamja [config file] contents, served at `/config.json` |
| `GAMJA_DATA_DIR`         | `/data/gamja`                               | Where gamja is installed; `update-gamja.sh` is copied to its parent directory |

Build arguments: `SOJU_REF` (default `c-port`) selects the soju source: the
tip of the `c-port` branch of pbtrung/soju-rs, or a pinned commit, branch or
tag. Only `amd64` images are supported. The image records the built commit
in `/usr/local/lib/soju/.revision` and the version in `.version`.
`TWINGATE_REF` (default
`latest`) selects the connector image tag. `GAMJA_REF` (default `latest`)
selects the gamja release tag bundled in the image. It's only installed on
a volume that doesn't have gamja yet. The branch tip and release metadata
are fetched on every build, so a rebuild picks up new commits and releases.

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
  - (optional) **Build arguments:** `SOJU_REF` to pin a soju commit, or
    `GAMJA_REF` a gamja release tag, instead of the latest
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

Add the initial admin credentials (the password as a secret), and the
backup destination if it differs from the default:

```
SOJU_ADMIN_USER=admin
SOJU_ADMIN_PASSWORD=<a strong initial password>
SOJU_BACKUP_REMOTE=<remote>:<bucket>/soju/
```

Click **Create service**. The startup log shows
`Starting the Twingate connector for network <network>`, then the
connector's `State: Online`; the connector also shows as connected in the
admin console.

### 6. Add a persistent volume

Required: the database lives on it. Open the service → **Volumes → Add
volume** (or attach the existing one):

- **Name:** `soju-data`
- **Size:** 1 GB is plenty with `message-expiry 5d`
- **Mount path:** `/data`

Then put the rclone config at `/data/rclone.conf` from a shell on the
container (see [Backups](#backups)).

### 7. Health check (recommended)

Service → **Health checks → Add health check**:

- **Protocol:** HTTP, **Port:** 8080, **Path:** `/healthz`
- Type: readiness and/or liveness. Liveness restarts the container if
  nginx stops answering.

### 8. Log in

With the Twingate client connected, open `http://soju.internal:8080`.
gamja loads. Log in with an existing user, or `SOJU_ADMIN_USER` /
`SOJU_ADMIN_PASSWORD` after bootstrap, then add an upstream network, either
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

`sojuctl` already knows where the config is (`/etc/soju/config`). soju
has no `sojudb`: the entrypoint creates the first admin with `sojuctl` over
the admin socket once soju is up.

### Backing up

See [Backups](#backups) above: daily `backup-soju.sh` with rclone. Northflank
volume backups also cover `/data`, but a snapshot taken while soju writes
the database may need its `-wal` file to be consistent.

### Updating

- Pushing to `main` triggers a rebuild and redeploy automatically, which
  also rebuilds soju from the tip of `c-port` and picks up the latest
  Twingate connector. The
  database survives redeploys on the volume; soju migrates its schema on
  startup (back it up before a major upgrade).
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
docker build --pull -t soju-nf soju-nf/
docker run --rm -p 8080:8080 -p 6667:6667 -v soju-nf-data:/data \
  -e SOJU_ADMIN_USER -e SOJU_ADMIN_PASSWORD \
  soju-nf
```

Export `SOJU_ADMIN_USER` and `SOJU_ADMIN_PASSWORD` before running the
command; avoid putting real passwords in shell history. Then open
http://localhost:8080. Without the `TWINGATE_*` variables, the connector
stays off; without `/data/rclone.conf`, backups are skipped.

## Notes

- Through Twingate, nginx sees every client at the connector's address, so
  the per-IP limits apply to all Twingate users together: 60 requests per
  minute for gamja's files (burst 30) and 20 concurrent connections. soju
  also sees that address as every client's host (`X-Forwarded-For`,
  trusted from loopback with `accept-proxy-ip localhost`). Any `Forwarded`
  header from a client is dropped, since soju prefers it.
- The connector runs as the `twingate` user, restarted 5 s after it exits.
  The entrypoint forwards shutdown to soju. If soju exits or admin
  bootstrap fails, the container stops so Northflank can restart it.
- gamja sends `PING` every 30 s by default (`GAMJA_CONFIG_JSON`) to keep
  its WebSocket open.
- `connectorctl health` in a shell on the container checks the connector.

[Northflank]: https://northflank.com/
[gamja]: https://codeberg.org/emersion/gamja
[pbtrung/gamja]: https://github.com/pbtrung/gamja
[Twingate connector]: https://www.twingate.com/docs/connectors
[soju]: https://soju.im/
[soju-rs]: https://github.com/pbtrung/soju-rs
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
