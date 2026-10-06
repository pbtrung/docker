# soju + gamja + nginx on Northflank

A single container image that runs:

- [soju] — IRC bouncer (built from `master`)
- [gamja] — IRC web client (built from `master`)
- nginx — serves gamja and proxies the IRC WebSocket (`/socket`) to soju.
  It replaces [kimchi], which the upstream [soju-containers] repo uses.

File uploads (IRCv3 filehost) are disabled: soju has no `file-upload`
backend and nginx doesn't proxy `/uploads`.

```
browser ──https──▶ Northflank LB ──▶ :8080 nginx ─┬─ /            gamja static files
                   (TLS terminated)               ├─ /config.json  gamja config
                                                  ├─ /socket       ─▶ soju 127.0.0.1:8081 (WebSocket)
                                                  └─ /healthz      200 ok
                                    :6667 soju plain IRC (private, in-project only)
```

Northflank only exposes HTTP ports publicly, so you reach the bouncer through
gamja in a browser. Port 6667 stays private: other services in the same
Northflank project can use it, but the internet can't.

Data (the SQLite DB) is stored in `/data`, which should be a
Northflank volume.

## Files

| File            | Purpose                                                              |
| --------------- | -------------------------------------------------------------------- |
| `Dockerfile`    | `builder` stage (alpine:edge) compiles soju + gamja; runtime stage on alpine:edge |
| `entrypoint.sh` | Writes the soju config from env vars, creates the first admin, starts nginx then soju |
| `nginx.conf`    | Serves gamja, proxies `/socket`, `/healthz`, rate limits |

## Environment variables

| Variable              | Default                                       | Description |
| --------------------- | --------------------------------------------- | ----------- |
| `SOJU_HOSTNAME`       | `soju`                                        | Server name shown to clients (gamja: "Connected to soju") |
| `SOJU_TITLE`          | —                                             | Server title shown to clients |
| `SOJU_ADMIN_USER`     | —                                             | Admin user created on first start (only while `/data/main.db` doesn't exist) |
| `SOJU_ADMIN_PASSWORD` | —                                             | Password for that admin user |
| `SOJU_EXTRA_CONFIG`   | —                                             | Extra soju config lines appended as-is (e.g. `max-user-networks 5`) |
| `SOJU_CONFIG_FILE`    | —                                             | Path to a complete soju config. If set, the env vars above that build the config are ignored |
| `GAMJA_CONFIG_JSON`   | `{"server":{"auth":"mandatory","ping":30}}`   | gamja [config file] contents, served at `/config.json` |
| `DATA_DIR`            | `/data`                                       | Where the DB is stored |
| `CLOUDFLARED_TOKEN`   | —                                             | Cloudflare Tunnel token. If set, runs cloudflared and binds IRC to loopback |

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

Click **Create service**. The first build takes a few minutes, mostly to
compile soju and bundle gamja.

### 6. Add a persistent volume

Without a volume, every redeploy wipes the database and all users.

Open the service → **Volumes → Add volume**:

- **Name:** `soju-data`
- **Size:** 1 GB is plenty to start
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

### 8. Public URL

The public URL is in the service's **Ports / DNS** section, e.g.
`https://p01--soju--abcd1234.code.run`. The server name shown in gamja
("Connected to soju") comes from `SOJU_HOSTNAME`, which defaults to `soju`.

**Custom domain (optional):** add it under the service's port **Domains**
(or the team's **Domains** page). Create the DNS record Northflank shows you
and wait for it to verify. Set `SOJU_HOSTNAME` to it too, if you want it
shown as the server name.

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
lives in `/data/main.db`.

## Cloudflare Tunnel (optional)

If `CLOUDFLARED_TOKEN` is set, the entrypoint:

1. binds soju's plain IRC listener to `127.0.0.1:6667` instead of
   `0.0.0.0:6667`, so nothing outside the container can reach it directly
2. runs `cloudflared tunnel --no-autoupdate run --token $CLOUDFLARED_TOKEN`
   in the background

cloudflared only makes outbound connections to Cloudflare, so it needs no
public or inbound port on Northflank. The public web UI on 8080 keeps working.

cloudflared's logs appear in the container console. If cloudflared exits
for any reason (bad token, crash), the container stops too and Northflank
restarts it, so the service never keeps running without its tunnel.

Set it up in the Cloudflare Zero Trust dashboard:

1. **Networks → Tunnels → Create a tunnel**, type **Cloudflared**. Name it
   (e.g. `soju`).
2. Copy the token from the install command shown (the long string after
   `--token`). In Northflank, add it as a **secret** environment variable
   `CLOUDFLARED_TOKEN` and save. The service restarts, and the tunnel shows
   as **Healthy** in the dashboard.
3. Add a **public hostname** route to the tunnel, for example:
   - `irc.example.org` → `tcp://localhost:6667` for native IRC clients. On
     each client machine, run
     `cloudflared access tcp --hostname irc.example.org --url localhost:6667`,
     then point the IRC client at `localhost:6667`.
   - `chat.example.org` → `http://localhost:8080` to serve gamja on your own
     domain through Cloudflare.

The routes live in Cloudflare (a remotely managed tunnel), so changing them
needs no redeploy.

## Run locally

```sh
docker build -t soju soju/
docker run --rm -p 8080:8080 -p 6667:6667 -v soju-data:/data \
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
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
