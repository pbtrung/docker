# soju + gamja + nginx on Northflank

A single container image that runs:

- [soju] — IRC bouncer (built from `master`)
- [gamja] — IRC web client (built from `master`)
- nginx — serves gamja and proxies the IRC WebSocket (`/socket`) and file
  uploads (`/uploads`) to soju. It replaces [kimchi], which the upstream
  [soju-containers] repo uses.

```
browser ──https──▶ Northflank LB ──▶ :8080 nginx ─┬─ /            gamja static files
                   (TLS terminated)               ├─ /config.json  gamja config
                                                  ├─ /socket       ─▶ soju 127.0.0.1:8081 (WebSocket)
                                                  ├─ /uploads      ─▶ soju 127.0.0.1:8081
                                                  └─ /healthz      200 ok
                                    :6667 soju plain IRC (private, in-project only)
```

Northflank only exposes HTTP ports publicly, so you reach the bouncer through
gamja in a browser. Port 6667 stays private: other services in the same
Northflank project can use it, but the internet can't.

Data (SQLite DB and uploaded files) is stored in `/data`, which should be a
Northflank volume.

## Files

| File            | Purpose                                                              |
| --------------- | -------------------------------------------------------------------- |
| `Dockerfile`    | `builder` stage (alpine:edge) compiles soju + gamja; runtime stage on alpine:edge |
| `entrypoint.sh` | Writes the soju config from env vars, creates the first admin, starts nginx then soju |
| `nginx.conf`    | Serves gamja, proxies `/socket` and `/uploads`, `/healthz`, rate limits |

## Environment variables

| Variable              | Default                                       | Description |
| --------------------- | --------------------------------------------- | ----------- |
| `SOJU_HOSTNAME`       | `soju`                                        | Server name shown to clients (gamja: "Connected to soju") |
| `SOJU_HTTP_INGRESS`   | — (**set this**)                              | Public base URL, e.g. `https://p01--soju--abcd1234.code.run`. soju builds upload links from it |
| `SOJU_TITLE`          | —                                             | Server title shown to clients |
| `SOJU_ADMIN_USER`     | —                                             | Admin user created on first start (only while `/data/main.db` doesn't exist) |
| `SOJU_ADMIN_PASSWORD` | —                                             | Password for that admin user |
| `SOJU_EXTRA_CONFIG`   | —                                             | Extra soju config lines appended as-is (e.g. `max-user-networks 5`) |
| `SOJU_CONFIG_FILE`    | —                                             | Path to a complete soju config. If set, the env vars above that build the config are ignored |
| `GAMJA_CONFIG_JSON`   | `{"server":{"auth":"mandatory","ping":30}}`   | gamja [config file] contents, served at `/config.json` |
| `DATA_DIR`            | `/data`                                       | Where the DB and uploads are stored |
| `CFMESH_CONF`         | `/data/cfmesh.conf`                           | WireGuard config for the mesh (run with wireproxy). Skipped if the file doesn't exist |
| `CFMESH_TCP_PORTS`    | `6667`                                        | Space-separated local TCP ports published on the mesh address |

Build arguments: `SOJU_REF` and `GAMJA_REF` (default `master`) select the git
branch or tag to build, e.g. `v0.11.1`.

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
  - **Dockerfile location:** `/soju/Dockerfile`
  - **Build context:** `/soju`
  - (optional) **Build arguments:** `SOJU_REF` / `GAMJA_REF` to pin a tag
    instead of `master`
- **Resources:** the smallest compute plan is enough. **Instances: 1.**

### 4. Networking

Northflank reads `EXPOSE` from the Dockerfile. Check the **Ports** section:

| Port | Protocol | Public |
| ---- | -------- | ------ |
| 8080 | HTTP     | **Yes** — gives you a `*.code.run` URL with TLS |
| 6667 | TCP      | No (Northflank can't make TCP ports public) |

If 8080 wasn't detected, add it by hand as **HTTP** and turn on **Publicly
expose this port to the internet**.

### 5. Environment variables

Under **Environment variables** (runtime), add:

```
SOJU_ADMIN_USER=admin
SOJU_ADMIN_PASSWORD=<a strong password>
SOJU_TITLE=My IRC
```

Leave `SOJU_HTTP_INGRESS` empty for now. You'll fill it in after the public
URL exists (step 8).

Click **Create service**. The first build takes a few minutes, mostly to
compile soju and bundle gamja.

### 6. Add a persistent volume

Without a volume, every redeploy wipes the database and all users.

Open the service → **Volumes → Add volume**:

- **Name:** `soju-data`
- **Size:** 1 GB is plenty to start (more if you expect many uploads)
- **Mount path:** `/data`

Save. The service restarts with the volume attached. A service with a volume
runs a single instance, which is what soju needs anyway.

> Order matters: the admin user is created only when `/data/main.db` doesn't
> exist yet. If the service started before the volume was attached, that
> first admin was written to the container's temporary disk. After you attach
> the volume, the service restarts, sees an empty `/data` and creates the
> admin again on the volume. Both outcomes are fine.

### 7. Health check (recommended)

Service → **Health checks → Add health check**:

- **Protocol:** HTTP, **Port:** 8080, **Path:** `/healthz`
- Type: readiness and/or liveness

### 8. Set the public URL

Copy the public URL from the service's **Ports / DNS** section, e.g.
`https://p01--soju--abcd1234.code.run`. Then set this environment variable
and save. The service restarts.

```
SOJU_HTTP_INGRESS=https://p01--soju--abcd1234.code.run
```

Without it, file upload links point to the wrong host. The server name shown
in gamja ("Connected to soju") comes from `SOJU_HOSTNAME`, which defaults to
`soju`.

**Custom domain (optional):** add it under the service's port **Domains**
(or the team's **Domains** page). Create the DNS record Northflank shows you
and wait for it to verify. Then set `SOJU_HTTP_INGRESS` to that domain
instead (and `SOJU_HOSTNAME` too, if you want it shown as the server name).

### 9. Log in

Open the public URL. gamja loads. Log in with `SOJU_ADMIN_USER` /
`SOJU_ADMIN_PASSWORD`.

Add an upstream IRC network. Either use gamja's "add network" UI, or message
`BouncerServ`:

```
/msg BouncerServ network create -addr ircs://irc.libera.chat -name libera -nick yournick
```

To connect to the network as `yournick` on Libera.Chat (SASL):

```
/msg BouncerServ sasl set-plain -network libera yournick <nickserv-password>
```

`/msg BouncerServ help` lists every command.

You can remove `SOJU_ADMIN_PASSWORD` from the env vars now. It's only used on
the very first start.

### 10. Manage users

As an admin in gamja:

```
/msg BouncerServ user create -username bob -password <password>
/msg BouncerServ user status
```

Or open a shell on the running container from the Northflank UI (service →
**Containers** → the container's **Shell** / terminal button) and run:

```
sojuctl user create -username bob -password <password>
sojuctl user status
```

`sojuctl` and `sojudb` already know where the config is (`/etc/soju/config`).

### Updating

- Pushing to `main` triggers a rebuild and redeploy automatically.
- To pick up new soju/gamja `master` commits without changing this repo,
  start a new build manually from the service's **Builds** tab.
- The database lives on the volume, so it survives redeploys. soju migrates
  its schema itself on startup.

### Backups

From the volume's page, take a backup or set up scheduled backups. Everything
lives in `/data`: `main.db` and `uploads/`.

## WireGuard mesh (optional)

The mesh uses [wireproxy], which runs WireGuard inside its own process. It
needs no `NET_ADMIN`, kernel module or `/dev/net/tun`, so it works on
Northflank, where `wg-quick` can't create an interface.

If the file at `CFMESH_CONF` exists, the entrypoint:

1. binds soju's plain IRC listener to `127.0.0.1:6667` instead of
   `0.0.0.0:6667`, so nothing outside the container can reach it directly
2. starts wireproxy with that config. For each port in `CFMESH_TCP_PORTS`
   (default `6667`), wireproxy listens on this node's mesh address and
   forwards connections to the same port on loopback.

The result: IRC is reachable only through the mesh, e.g.
`irc+insecure://<this node's mesh IP>:6667` from another peer. The public web
UI on 8080 keeps working. Set `CFMESH_TCP_PORTS="6667 8080"` to also reach it
over the mesh.

Example `cfmesh.conf` (a standard WireGuard config):

```ini
[Interface]
PrivateKey = <this node's private key>
Address = 10.99.0.1/32

[Peer]
PublicKey = <peer's public key>
Endpoint = peer.example.org:51820
AllowedIPs = 10.99.0.0/24
PersistentKeepalive = 25
```

- **This node must start the tunnel.** Northflank can't expose a UDP port,
  so peers can't reach this container first. Every `[Peer]` it should talk
  to needs an `Endpoint` and `PersistentKeepalive`.
- If the config is invalid, the container exits with an error rather than
  running without the mesh.
- wireproxy only forwards TCP ports. It does not create a network interface,
  so there's no `cfmesh` device, `ping` from inside, or routing.

To provide the config on Northflank, add it as a **secret file** under the
service's environment settings (e.g. at `/secrets/cfmesh.conf`) and set
`CFMESH_CONF=/secrets/cfmesh.conf`. You can also put it on the volume at
`/data/cfmesh.conf`.

## Run locally

```sh
docker build -t soju soju/
docker run --rm -p 8080:8080 -p 6667:6667 -v soju-data:/data \
  -e SOJU_HTTP_INGRESS=http://localhost:8080 \
  -e SOJU_ADMIN_USER=admin -e SOJU_ADMIN_PASSWORD=changeme \
  soju
```

Then open http://localhost:8080. You can also point a native IRC client at
`localhost:6667` (plain text, no TLS, password `changeme`).

## Notes

- **Native IRC clients** (irssi, WeeChat, …) can't reach port 6667 from the
  internet on Northflank, because it only exposes HTTP ports. Use gamja.
  Clients that support IRC over WebSocket can connect to
  `wss://<host>/socket`.
- gamja sends `PING` every 30 s by default (`GAMJA_CONFIG_JSON`). This keeps
  idle WebSockets from being cut by load balancer timeouts.
- nginx forwards client IPs via `X-Forwarded-For`. soju trusts it from
  loopback (`accept-proxy-ip localhost`).
- Building from `master` gives you the newest features, but `master` may be
  unstable. Set `SOJU_REF` / `GAMJA_REF` build arguments to a release tag for
  a stable deploy.

[soju]: https://soju.im/
[gamja]: https://codeberg.org/emersion/gamja
[kimchi]: https://codeberg.org/emersion/kimchi
[soju-containers]: https://codeberg.org/emersion/soju-containers
[wireproxy]: https://github.com/whyvl/wireproxy
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
