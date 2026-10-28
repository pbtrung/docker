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

## Turso storage

Accounts and messages live in Turso Cloud, using soju-rs v0.99.19 or
later. On startup, soju creates the controller database in the configured
group if needed. The controller holds login accounts and links to each
user's separate database, which stores their networks and messages. User
database names are random 128-bit values encoded as 25 lowercase letters
and digits. The Turso organization and group must already exist.

Set these runtime environment variables (mark both tokens as secrets):

```text
TURSO_ORGANIZATION=<organization slug>
TURSO_GROUP=<database group>
TURSO_CONTROLLER=soju-controller
TURSO_GROUP_TOKEN=<read-write SQL token for the entire group>
TURSO_API_TOKEN=<Turso Platform API token>
SOJU_ADMIN_USER=admin
SOJU_ADMIN_PASSWORD=<a strong initial password>
```

The entrypoint renders `message-store turso` and the five `turso-*`
settings into `/etc/soju/config`. The config is owned by `soju`, mode 600,
and its contents are never printed. `TURSO_CONTROLLER` defaults to
`soju-controller`; the other four Turso variables are required. The group
token authorizes SQL against all databases in the group. The separate API
token needs permission to read, create, and delete databases; a group SQL
token cannot provision them. Keep the group dedicated to this instance.

When `SOJU_ADMIN_PASSWORD` is set, startup checks `SOJU_ADMIN_USER`
(default `admin`) through the admin socket. A missing account is created
as an admin, together with its user database. An existing admin keeps its
stored password. An existing non-admin account or an account lookup or
creation failure stops the container. No local marker controls bootstrap,
so restarts and replacement volumes work. Remove `SOJU_ADMIN_PASSWORD`
after setup; changing this variable does not reset an existing password.

`soju.conf` sets `message-expiry 5d`: messages older than five days are
deleted at startup and daily. Turso does not run `VACUUM`, checkpoints, or
other local SQLite maintenance. Set `message-expiry 0d` in a custom base
config selected with `SOJU_CONFIG_FILE` to retain messages forever. A
custom template must keep `message-store turso`, the admin listener at
`/run/soju/admin`, and omit `db` and all `turso-*` directives: the latter
come from the environment. The template must be a separate file from the
generated `/etc/soju/config`.

### Existing SQLite deployments and backups

Switching this image to Turso does **not** import `/data/soju/main.db`.
Existing local users, networks, and messages are not loaded into Turso.
Keep the old database and its backups if you need that data; this image
leaves those files untouched. The old SQLite/rclone backup job is removed
because local snapshots would not back up the cloud databases. Manage
backups for the controller and every user database through Turso.

`/data` is now optional for account and message persistence. A Northflank
volume there still preserves your installed gamja version and updater:

```text
/data/
├── gamja/           gamja web client (GAMJA_DATA_DIR)
└── update-gamja.sh  gamja updater, copied on every start
```

## Files

| File            | Purpose |
| --------------- | ------- |
| `Dockerfile`    | `builder` stage (alpine:edge) downloads a soju-rs release (checked against its `SHA256SUMS`) and a gamja release, and copies the Twingate connector (with its glibc libraries) from `twingate/connector:1`; runtime stage on alpine:edge installs nginx and su-exec with `apk` |
| `soju.conf`     | Base config installed at `/usr/share/soju/config`: Turso storage, message expiry, `chathistory-limit`, listeners, hostname |
| `configure-soju.sh` | Validates environment variables and renders the private `/etc/soju/config` with escaped Turso values |
| `soju-wrapper.sh` | Installed as `soju` and `sojuctl`: runs the soju-rs binary with `-config /etc/soju/config` |
| `entrypoint.sh` | Renders config, installs gamja, starts the connector and soju, bootstraps the admin, then starts nginx; forwards shutdown to soju |
| `update-gamja.sh` | Installs a gamja release (latest, or a given tag) into `GAMJA_DATA_DIR` (`/data/gamja`) |
| `nginx.conf`    | Serves gamja, `/config.json` and `/healthz`, proxies `/socket` to soju, per-IP limits |

## Environment variables

| Variable                 | Default                                     | Description |
| ------------------------ | ------------------------------------------- | ----------- |
| `TWINGATE_NETWORK`       | —                                           | Twingate network name (the `<network>` of `<network>.twingate.com`) |
| `TWINGATE_ACCESS_TOKEN`  | —                                           | Connector access token. **Secret** |
| `TWINGATE_REFRESH_TOKEN` | —                                           | Connector refresh token. **Secret**. The connector only starts when all three are set; the tokens are removed from the environment before nginx and soju start |
| `TWINGATE_RESOURCE_HOST` | `soju.internal`                             | Name of the Twingate Resource: mapped to the container's own IPv4 address in `/etc/hosts` on every start |
| `TURSO_ORGANIZATION`     | Required                                    | Turso organization slug (`turso-organization`) |
| `TURSO_GROUP`            | Required                                    | Existing database group (`turso-group`) |
| `TURSO_CONTROLLER`       | `soju-controller`                           | Controller database name (`turso-controller`) |
| `TURSO_GROUP_TOKEN`      | Required                                    | Read-write SQL token for every database in the group (`turso-group-token`). **Secret** |
| `TURSO_API_TOKEN`        | Required                                    | Platform API token for database provisioning (`turso-api-token`). **Secret** |
| `SOJU_ADMIN_USER`        | `admin`                                     | Bootstrap admin username, checked when `SOJU_ADMIN_PASSWORD` is set |
| `SOJU_ADMIN_PASSWORD`    | —                                           | Initial password for a missing bootstrap admin. **Secret**; existing passwords are kept |
| `SOJU_CONFIG_FILE`       | —                                           | Path to a base config template; storage stays Turso and credentials come from `TURSO_*` |
| `GAMJA_CONFIG_JSON`      | `{"server":{"auth":"mandatory","ping":30}}` | gamja [config file] contents, served at `/config.json` |
| `GAMJA_DATA_DIR`         | `/data/gamja`                               | Where gamja is installed; `update-gamja.sh` is copied to its parent directory |

Build arguments: `SOJU_REF` (default `latest`) selects the
[soju-rs release][soju-rs releases] to install (v0.99.19 or later; older releases are rejected at build time).
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

Add the required Turso settings and initial admin credentials (store
the tokens and password as secrets):

```
TURSO_ORGANIZATION=<organization slug>
TURSO_GROUP=<database group>
TURSO_CONTROLLER=soju-controller
TURSO_GROUP_TOKEN=<read-write group SQL token>
TURSO_API_TOKEN=<Platform API token>
SOJU_ADMIN_USER=admin
SOJU_ADMIN_PASSWORD=<a strong initial password>
```

Click **Create service**. The startup log shows
`Starting the Twingate connector for network <network>`, then the
connector's `State: Online`; the connector also shows as connected in the
admin console.

### 6. Add an optional persistent volume

This is optional for Turso: users, networks, and messages survive redeploys
in the cloud databases. Attach a volume to preserve gamja updates across
redeploys. A fresh container without one reinstalls bundled gamja.

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

`sojuctl` already knows where the config is (`/etc/soju/config`). soju-rs
has no `sojudb`: the entrypoint creates the first admin with `sojuctl` over
the admin socket once soju is up.

### Backups

Back up the controller and all user databases in Turso. Northflank
volume backups only cover files such as gamja and any retained old SQLite
database, not the cloud databases.

### Updating

- Pushing to `main` triggers a rebuild and redeploy automatically, which
  also picks up the latest soju-rs release and `1.x` Twingate connector.
  Turso databases survive redeploys; soju migrates their schemas on startup.
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
  -e TURSO_ORGANIZATION -e TURSO_GROUP -e TURSO_CONTROLLER \
  -e TURSO_GROUP_TOKEN -e TURSO_API_TOKEN \
  -e SOJU_ADMIN_USER -e SOJU_ADMIN_PASSWORD \
  soju-nf
```

Export the environment variables listed in [Turso storage](#turso-storage)
before running the command; avoid putting real tokens or passwords in shell
history. Then open http://localhost:8080. Without the `TWINGATE_*` variables, the
connector stays off.

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
[soju-rs releases]: https://github.com/pbtrung/soju-rs/releases
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
