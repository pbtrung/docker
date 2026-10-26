# gamja + nginx on Northflank, behind Twingate

A single container image for [Northflank] that runs:

- [gamja] — IRC web client, prebuilt release from the [pbtrung/gamja] fork,
  kept on the volume so it can be updated from a shell
- nginx — serves gamja, `/config.json` and `/healthz` on plain HTTP port
  8080
- a [Twingate connector] — the only way in from outside: it only makes
  outbound connections to Twingate, so no port is public

soju isn't in this image yet: gamja is served, but has no bouncer behind
it. Point it at one with `GAMJA_CONFIG_JSON` (`server.url`), see the
[gamja config file] docs.

```
browser ─Twingate─▶ connector (same container) ─▶ soju.internal:8080 nginx ─┬─ /            gamja static files
                                                                            ├─ /config.json  gamja config
                                                                            └─ /healthz      200 ok
Northflank health check ──▶ nginx :8080
```

`/data` should be a Northflank volume. It holds:

```
/data/
├── gamja/            gamja web client (GAMJA_DATA_DIR)
└── update-gamja.sh   gamja updater, copied on every start
```

## Files

| File            | Purpose |
| --------------- | ------- |
| `Dockerfile`    | `builder` stage (alpine:edge) downloads a gamja release, and copies the Twingate connector (with its glibc libraries) from `twingate/connector:1`; runtime stage on alpine:edge installs nginx with `apk` |
| `entrypoint.sh` | Installs gamja on the volume, writes the gamja config, maps `TWINGATE_RESOURCE_HOST` to the container's address, starts the Twingate connector, then nginx |
| `update-gamja.sh` | Installs a gamja release (latest, or a given tag) into `GAMJA_DATA_DIR` (`/data/gamja`) |
| `nginx.conf`    | Serves gamja, `/config.json` and `/healthz`, per-IP limits |

## Environment variables

| Variable                 | Default                                     | Description |
| ------------------------ | ------------------------------------------- | ----------- |
| `TWINGATE_NETWORK`       | —                                           | Twingate network name (the `<network>` of `<network>.twingate.com`) |
| `TWINGATE_ACCESS_TOKEN`  | —                                           | Connector access token. **Secret** |
| `TWINGATE_REFRESH_TOKEN` | —                                           | Connector refresh token. **Secret**. The connector only starts when all three are set; the tokens are removed from the environment before nginx starts |
| `TWINGATE_RESOURCE_HOST` | `soju.internal`                             | Name of the Twingate Resource: mapped to the container's own IPv4 address in `/etc/hosts` on every start |
| `GAMJA_CONFIG_JSON`      | `{"server":{"auth":"mandatory","ping":30}}` | gamja [config file] contents, served at `/config.json` |
| `GAMJA_DATA_DIR`         | `/data/gamja`                               | Where gamja is installed; `update-gamja.sh` is copied to its parent directory |

Build argument: `GAMJA_REF` (default `latest`) selects the gamja release tag
bundled in the image. It's only installed on a volume that doesn't have gamja
yet.

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
   and port `8080`, and give your group access to it.

Each Resource name can only be used once across Remote Networks: if another
one already has a `soju.internal` Resource, set `TWINGATE_RESOURCE_HOST`
to another name here.

From a device running the Twingate client, gamja is at
`http://soju.internal:8080`. The browser must resolve the name through the
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

Northflank reads `EXPOSE` from the Dockerfile and adds port 8080. Keep it
**private**: turn off **Publicly expose this port to the internet**.
Twingate reaches it from inside the container, and the health check
doesn't need it public either.

### 5. Environment variables

Under **Environment variables** (runtime), add the Twingate values, as
**secrets** for the tokens:

```
TWINGATE_NETWORK=<network>
TWINGATE_ACCESS_TOKEN=<access token>
TWINGATE_REFRESH_TOKEN=<refresh token>
```

Click **Create service**. The startup log shows
`Starting the Twingate connector for network <network>`, then the
connector's `State: Online`; the connector also shows as connected in the
admin console.

### 6. Add a persistent volume

Without a volume, every redeploy reinstalls the gamja bundled in the image,
undoing `update-gamja.sh`.

Open the service → **Volumes → Add volume**:

- **Name:** `soju-data`
- **Size:** 1 GB is plenty
- **Mount path:** `/data`

### 7. Health check (recommended)

Service → **Health checks → Add health check**:

- **Protocol:** HTTP, **Port:** 8080, **Path:** `/healthz`
- Type: readiness and/or liveness. Liveness restarts the container if
  nginx stops answering.

### Updating

- Pushing to `main` triggers a rebuild and redeploy automatically, which
  also picks up the latest `1.x` Twingate connector.
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
docker run --rm -p 8080:8080 -v soju-nf-data:/data soju-nf
```

Then open http://localhost:8080. Without the `TWINGATE_*` variables, the
connector stays off.

## Notes

- Through Twingate, nginx sees every client at the connector's address, so
  the per-IP limits apply to all Twingate users together: 60 requests per
  minute for gamja's files (burst 30) and 20 concurrent connections.
- The connector runs as the `twingate` user, restarted 5 s after it exits.
  nginx is the main process: if it exits, the container stops and
  Northflank restarts it.
- `connectorctl health` in a shell on the container checks the connector.

[Northflank]: https://northflank.com/
[gamja]: https://codeberg.org/emersion/gamja
[pbtrung/gamja]: https://github.com/pbtrung/gamja
[Twingate connector]: https://www.twingate.com/docs/connectors
[gamja config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
