# WeeChat + Glowing Bear + nginx on Northflank

A single container image that runs:

- [WeeChat] — IRC client, headless (`weechat-headless`), from Alpine edge
  with the Perl, Python and Lua script plugins
- [Glowing Bear] — WeeChat web client (built from `master`)
- nginx — serves Glowing Bear and proxies the relay WebSocket (`/weechat`) to
  WeeChat's relay

```
browser ──https──▶ Northflank LB ──▶ :8080 nginx ─┬─ /          Glowing Bear static files
                   (TLS terminated)               ├─ /weechat   ─▶ WeeChat relay 127.0.0.1:9001 (WebSocket)
                                                  └─ /healthz   200 ok
                                    WeeChat ──▶ IRC networks (outbound only)
```

WeeChat stays connected to your IRC networks around the clock. Glowing Bear
in the browser is the UI. It talks to WeeChat's relay over the WeeChat relay
protocol, through nginx. The relay only listens on loopback, so nginx is the
only way in.

Everything WeeChat writes is stored in `/data/weechat`: config, chat logs and
scripts. `/data` should be a Northflank volume.

## Files

| File            | Purpose |
| --------------- | ------- |
| `Dockerfile`    | `builder` stage (alpine:edge) builds Glowing Bear and fetches cloudflared; runtime stage on alpine:edge with WeeChat from apk |
| `entrypoint.sh` | Applies WeeChat settings, starts cloudflared (optional) and nginx, then runs WeeChat as PID 1 |
| `nginx.conf`    | Serves Glowing Bear, proxies `/weechat`, `/healthz`, rate limits |
| `weechat-cmd`   | Shell helper that sends a command to the running WeeChat through its FIFO |

## How WeeChat runs

`weechat-headless` runs in the foreground as the container's main process
(PID 1), as user `weechat` (uid 1000), with `--stdout` so its log messages go
to the container console. That is WeeChat's daemon mode for containers:
`--daemon` would fork into the background, PID 1 would exit and the container
would stop. Northflank restarts the container if WeeChat exits.

On `docker stop` / redeploy, WeeChat gets `SIGTERM`, saves its config and
quits cleanly.

## WeeChat configuration

The entrypoint passes commands to WeeChat with `--run-command`.

**On the first start only** (while `/data/weechat/weechat.conf` doesn't
exist), it sets these defaults. You can change any of them later from Glowing
Bear and your change is kept:

| Setting | Value | Why |
| ------- | ----- | --- |
| `logger.file.rotation_size_max` | `10m` | Rotate each chat log at 10 MB |
| `logger.file.rotation_compression_type` | `zstd` | Compress rotated logs (`#chan.weechatlog.1.zst`, …) |
| `logger.file.rotation_compression_level` | `50` | Mid-level compression (1–100) |
| `irc.look.smart_filter` + filter `irc_smart` | on | Hide join/part/quit from people who haven't spoken recently |
| `irc.server_default.autojoin_dynamic` | on | Channels you `/join` and `/part` are saved in the autojoin list |
| `relay.look.auto_open_buffer` | off | Don't open the relay buffer whenever a client connects |
| `weechat.plugin.autoload` | `*,!xfer` | No DCC, which can't work behind the load balancer |
| `irc.ctcp.{action,clientinfo,finger,ping,source,time,userinfo,version}` | `""` | Don't answer CTCP requests, which reveal client version, local time, etc. |
| `irc.server_default.msg_part` / `msg_quit` | `""` | No `WeeChat <version>` part/quit messages |
| `fifo.file.path` | `${weechat_runtime_dir}/weechat_fifo` | Stable FIFO path for `weechat-cmd` |

The DCC, CTCP and part/quit settings come from atoponce's
[WeeChat privacy gist]. Its optional `/mode <nick> -G+g` step (blocking
private messages from unregistered users) depends on the network and your
nick, so it isn't applied. Run it yourself after connecting, on networks that
support it.

Chat logs live in `/data/weechat/logs`.

**On every start**, it enforces the relay settings:

| Setting | Value |
| ------- | ----- |
| `relay.network.bind_address` | `127.0.0.1` |
| `relay.network.ipv6` | `off` |
| `relay.network.password` | `${env:WEECHAT_RELAY_PASSWORD}` |
| `relay.network.totp_secret` | `${env:WEECHAT_RELAY_TOTP_SECRET}` |
| `relay.port.weechat` | `9001` |

The password and TOTP secret are stored as `${env:…}` references, never as
plain values. WeeChat reads them from the environment each time a client logs
in. Changing the env var and restarting changes the password.

Then it runs `WEECHAT_EXTRA_COMMANDS` (if set) and `/save`.

See the [WeeChat user's guide] for every option, or use `/fset` in Glowing
Bear to browse them.

## Environment variables

| Variable                     | Default         | Description |
| ---------------------------- | --------------- | ----------- |
| `WEECHAT_RELAY_PASSWORD`     | — (**required**) | Password Glowing Bear uses to log in to the relay. The container won't start without it |
| `WEECHAT_RELAY_TOTP_SECRET`  | —               | Base32 TOTP secret. If set, Glowing Bear also asks for a one-time code |
| `WEECHAT_EXTRA_COMMANDS`     | —               | WeeChat commands run on every start, separated by `;` (e.g. `/set weechat.look.buffer_time_format "%H:%M"`) |
| `DATA_DIR`                   | `/data`         | Persistent volume mount point |
| `WEECHAT_HOME`               | `$DATA_DIR/weechat` | WeeChat home directory (config, logs, scripts, FIFO) |
| `CLOUDFLARED_TOKEN`          | —               | Cloudflare Tunnel token. If set, runs cloudflared |
| `TZ`                         | UTC             | Time zone for timestamps and log files, e.g. `Asia/Ho_Chi_Minh` |

Build argument: `GLOWING_BEAR_REF` (default `master`) selects the Glowing
Bear git branch or tag to build.

## Deploy on Northflank (web UI)

### 1. Push this repo to a Git provider

Push this repository to GitHub, GitLab or Bitbucket. In Northflank, open
**Account / Team settings → Git integrations** and connect that provider.
Give Northflank access to the repository.

### 2. Create a project

**Create new → Project**. Pick a name (e.g. `irc`) and a region close to you.
If you already run `soju-nf`, reuse its project.

### 3. Create a combined service

Inside the project: **Create new → Service → Combined service** (this builds
from Git and deploys in one service).

- **Name:** `weechat`
- **Repository:** this repo, branch `main`
- **Build type:** `Dockerfile`
  - **Dockerfile location:** `/weechat-nf/Dockerfile`
  - **Build context:** `/weechat-nf`
  - (optional) **Build arguments:** `GLOWING_BEAR_REF` to pin a tag
- **Resources:** the smallest compute plan is enough. **Instances: 1.**

### 4. Networking

Northflank reads `EXPOSE` from the Dockerfile. Check the **Ports** section:

| Port | Protocol | Public |
| ---- | -------- | ------ |
| 8080 | HTTP     | **Yes** — gives you a `*.code.run` URL with TLS |

If 8080 wasn't detected, add it by hand as **HTTP** and turn on **Publicly
expose this port to the internet**.

### 5. Environment variables

Under **Environment variables** (runtime), add as **secrets**:

```
WEECHAT_RELAY_PASSWORD=<a long random password>
TZ=Asia/Ho_Chi_Minh
```

Generate a password with e.g. `openssl rand -base64 24`. The relay is
reachable from the internet, so make it long.

Click **Create service**. The first build takes a few minutes, mostly to
bundle Glowing Bear.

### 6. Add a persistent volume

Without a volume, every redeploy wipes your servers, settings and logs.

Open the service → **Volumes → Add volume**:

- **Name:** `weechat-data`
- **Size:** 1 GB is plenty to start (logs are rotated and compressed)
- **Mount path:** `/data`

Save. The service restarts with the volume attached and applies the
first-start defaults to it.

### 7. Health check (recommended)

Service → **Health checks → Add health check**:

- **Protocol:** HTTP, **Port:** 8080, **Path:** `/healthz`
- Type: readiness and/or liveness

### 8. Connect with Glowing Bear

Open the public URL from the service's **Ports / DNS** section, e.g.
`https://p01--weechat--abcd1234.code.run`. On the Glowing Bear start page:

- **WeeChat relay hostname and port number:**
  `p01--weechat--abcd1234.code.run:443` (path defaults to `weechat`)
- **WeeChat relay password:** `WEECHAT_RELAY_PASSWORD`
- **Encryption (TLS):** checked
- optionally **Automatically connect** and **Save password**

Click **Connect**.

**Custom domain (optional):** add it under the service's port **Domains**,
create the DNS record Northflank shows you, then use that hostname in
Glowing Bear instead.

### 9. Add an IRC network

Type in the Glowing Bear input bar (the core `weechat` buffer):

```
/server add libera irc.libera.chat/6697 -tls
/set irc.server.libera.nicks "yournick,yournick_"
/set irc.server.libera.sasl_mechanism plain
/set irc.server.libera.sasl_username "yournick"
/secure set libera <nickserv-password>
/set irc.server.libera.sasl_password "${sec.data.libera}"
/set irc.server.libera.autoconnect on
/connect libera
/join #weechat
```

With `autojoin_dynamic` on, joined channels are remembered across restarts.
Settings are saved automatically when WeeChat stops; run `/save` to save
right away.

### 10. Scripts

```
/script install go.py
/script install autosort.py
```

Scripts are installed into `/data/weechat`, so they survive redeploys.

### Updating

- Pushing to `main` triggers a rebuild and redeploy automatically.
- To pick up new WeeChat, Alpine or Glowing Bear versions without changing
  this repo, start a new build manually from the service's **Builds** tab.
- Config and logs live on the volume and survive redeploys.

### Backups

From the volume's page, take a backup or set up scheduled backups.
Everything lives in `/data/weechat`.

## Shell access

Open a shell on the running container from the Northflank UI (service →
**Containers** → the container's **Shell** / terminal button).

WeeChat has no terminal UI in headless mode. To run a command, write it to the
FIFO with `weechat-cmd`:

```sh
weechat-cmd '/connect libera'
weechat-cmd '/set relay.network.max_clients 10'
weechat-cmd 'irc.libera.#weechat' 'hello from the shell'
```

The output goes to WeeChat's buffers (visible in Glowing Bear), not the
shell. Config files are in `/data/weechat/*.conf`. Edit them only while
WeeChat is stopped, or run `weechat-cmd '/reload'` afterwards.

## Cloudflare Tunnel (optional)

If `CLOUDFLARED_TOKEN` is set, the entrypoint runs
`cloudflared tunnel --no-autoupdate run --token $CLOUDFLARED_TOKEN` in the
background. cloudflared only makes outbound connections to Cloudflare, so it
needs no public or inbound port on Northflank. The public URL on 8080 keeps
working.

cloudflared's logs appear in the container console. If cloudflared exits
for any reason (bad token, crash), the container stops too and Northflank
restarts it, so the service never keeps running without its tunnel.

Set it up in the Cloudflare Zero Trust dashboard:

1. **Networks → Tunnels → Create a tunnel**, type **Cloudflared**. Name it
   (e.g. `weechat`).
2. Copy the token from the install command shown (the long string after
   `--token`). In Northflank, add it as a **secret** environment variable
   `CLOUDFLARED_TOKEN` and save. The service restarts, and the tunnel shows
   as **Healthy** in the dashboard.
3. Add a **public hostname** route to the tunnel, e.g.
   `weechat.example.org` → `http://localhost:8080`. Glowing Bear and the
   relay are then served on your own domain through Cloudflare (connect with
   `weechat.example.org:443`). You can put a Cloudflare Access policy in
   front of it for an extra login.

The routes live in Cloudflare (a remotely managed tunnel), so changing them
needs no redeploy.

## Run locally

```sh
docker build -t weechat weechat-nf/
docker run --rm -p 8080:8080 -v weechat-data:/data \
  -e WEECHAT_RELAY_PASSWORD=changeme \
  weechat
```

Then open http://localhost:8080 and connect to `localhost:8080`, password
`changeme`, **TLS unchecked**.

## Notes

- **Other relay clients** that speak the `weechat` relay protocol over
  WebSocket (e.g. WeeChat Android) connect the same way: host `<host>`,
  port 443, TLS, WebSocket path `/weechat`. The relay's own TCP port is
  loopback-only.
- nginx allows 10 relay connection attempts per minute per client IP (burst
  5) to slow down password guessing. Add `WEECHAT_RELAY_TOTP_SECRET` for a
  second factor.
- Glowing Bear stores its settings (and the password, if you tick **Save
  password**) in the browser's local storage.
- `WEECHAT_EXTRA_COMMANDS` runs on every start, so a setting it changes can't
  be changed permanently from Glowing Bear. Use it only for settings you want
  pinned.

[WeeChat]: https://weechat.org/
[WeeChat user's guide]: https://weechat.org/doc/
[Glowing Bear]: https://github.com/glowing-bear/glowing-bear
[WeeChat privacy gist]: https://gist.github.com/atoponce/f19666d6b206a10b411b97381a1861a1
