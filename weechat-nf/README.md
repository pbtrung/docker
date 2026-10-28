# WeeChat + Glowing Bear + nginx on Northflank, behind Twingate

A single container image that runs:

- [WeeChat] — IRC client, headless (`weechat-headless`), from Alpine edge
  with only the Lua script plugin installed (disabled at startup)
- [Glowing Bear] — WeeChat web client, prebuilt release from the
  [pbtrung/glowing-bear] fork, kept on the volume so it can be updated from a
  shell
- nginx — serves Glowing Bear and proxies the relay API (`/api`, HTTP and
  WebSocket) to WeeChat's relay
- a [Twingate connector] — outbound connections only; keep port 8080 private

```
browser ─Twingate─▶ connector (same container) ─▶ weechat.internal:8080 nginx
                                                 ├─ /          Glowing Bear static files
                                                 ├─ /api       ─▶ WeeChat relay 127.0.0.1:9001 (HTTP + WebSocket)
                                                 └─ /healthz   200 ok
Northflank health check ──▶ nginx :8080
WeeChat ──▶ IRC networks (outbound only)
```

WeeChat stays connected to your IRC networks around the clock. Glowing Bear
in the browser is the UI. It talks to WeeChat's relay over the `api` relay
protocol (WeeChat 4.1+), through nginx. The relay only listens on loopback, so nginx is the
only way in.

Everything WeeChat writes is stored in `/data/weechat`: config, chat logs and
scripts. Glowing Bear is in `/data/glowing-bear`. `/data` should be a
Northflank volume.

## Files

| File            | Purpose |
| --------------- | ------- |
| `Dockerfile`    | Downloads a Glowing Bear release and copies the Twingate connector with its glibc libraries from `twingate/connector:1`, as in `soju-fly`; runtime on alpine:edge with WeeChat, weechat-lua and rclone from apk |
| `entrypoint.sh` | Installs Glowing Bear and helper scripts on the volume, applies WeeChat settings, maps the Twingate Resource hostname to the container IPv4, starts cron, the connector and nginx, then runs WeeChat as PID 1 |
| `update-glowing-bear.sh` | Installs a Glowing Bear release (latest, or a given tag) into `/data/glowing-bear` |
| `backup-weechat.sh` | Archives only WeeChat `*.conf` files, uploads them with rclone and removes rotated `*.zst` logs; run daily by BusyBox crond |
| `nginx.conf`    | Serves Glowing Bear, proxies `/api`, `/healthz`, rate limits |
| `weechat-cmd`   | Shell helper that sends a command to the running WeeChat through its FIFO |

## How WeeChat runs

`weechat-headless` runs in the foreground as the container's main process
(PID 1), as user `weechat` (uid 1000), with `--stdout` so its log messages go
to the container console. That is WeeChat's daemon mode for containers:
`--daemon` would fork into the background, PID 1 would exit and the container
would stop. Northflank restarts the container if WeeChat exits.

WeeChat uses mimalloc from Alpine's `mimalloc3` package, preloaded with
`LD_PRELOAD=/usr/lib/libmimalloc.so.3` when launching `weechat-headless`.

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
| `irc.ctcp.{action,clientinfo,finger,ping,source,time,userinfo,version}` | `""` | Don't answer CTCP requests, which reveal client version, local time, etc. |
| `irc.server_default.msg_part` / `msg_quit` | `""` | No `WeeChat <version>` part/quit messages |
| `fifo.file.path` | `${weechat_runtime_dir}/weechat_fifo` | Stable FIFO path for `weechat-cmd` |

The CTCP and part/quit settings, and disabling DCC below, come from atoponce's
[WeeChat privacy gist]. Its optional `/mode <nick> -G+g` step (blocking
private messages from unregistered users) depends on the network and your
nick, so it isn't applied. Run it yourself after connecting, on networks that
support it.

Chat logs live in `/data/weechat/logs`.

**On every start**, including existing volumes, it limits each buffer to
500 history lines and disables automatic loading of scripting plugins and
DCC:

```
/set weechat.history.max_buffer_lines_number 500
/set weechat.plugin.autoload "*,!python,!perl,!ruby,!lua,!tcl,!guile,!javascript,!php,!xfer"
```

It also unloads these plugins for the current session, since WeeChat loads
plugins before processing startup commands. Only `weechat-lua` is installed;
load it explicitly with `/plugin load lua` when needed.

It explicitly loads the relay plugin before enforcing the relay settings.
This also handles volumes from the older terminal-only setup, which disabled
relay autoload; changing the autoload setting alone takes effect on the next
start.

| Setting | Value |
| ------- | ----- |
| `relay.network.bind_address` | `127.0.0.1` |
| `relay.network.ipv6` | `off` |
| `relay.network.password` | `${env:WEECHAT_RELAY_PASSWORD}` |
| `relay.network.totp_secret` | `""` |
| `relay.network.password_hash_iterations` | `1000` (PBKDF2 rounds; default 100000, slow on phones) |
| `relay.port.api` | `9001` |

The password is stored as an `${env:…}` reference, never as a plain value.
WeeChat reads it from the environment each time a client logs in. Changing
the env var and restarting changes the password.

TOTP is forced off: the fork can't send a one-time code on the WebSocket
connection, so a TOTP secret would lock Glowing Bear out. A `weechat`
protocol relay left on port 9001 by an older version of this image is
removed.

Then it runs `WEECHAT_EXTRA_COMMANDS` (if set) and `/save`.

See the [WeeChat user's guide] for every option, or use `/fset` in Glowing
Bear to browse them.

## Environment variables

| Variable                     | Default         | Description |
| ---------------------------- | --------------- | ----------- |
| `WEECHAT_RELAY_PASSWORD`     | — (**required**) | Password Glowing Bear uses to log in to the relay. The container won't start without it |
| `WEECHAT_BACKUP_REMOTE`      | — (**required**) | rclone upload destination, e.g. `tigris:skypiea/weechat/`. The container and backup script refuse to run if unset or empty |
| `WEECHAT_EXTRA_COMMANDS`     | —               | WeeChat commands run on every start, separated by `;` (e.g. `/set weechat.look.buffer_time_format "%H:%M"`) |
| `DATA_DIR`                   | `/data`         | Persistent volume mount point |
| `WEECHAT_HOME`               | `$DATA_DIR/weechat` | WeeChat home directory (config, logs, scripts, FIFO) |
| `TWINGATE_NETWORK`          | —               | Twingate network name (`<network>` in `<network>.twingate.com`) |
| `TWINGATE_ACCESS_TOKEN`     | —               | Connector access token. **Secret** |
| `TWINGATE_REFRESH_TOKEN`    | —               | Connector refresh token. **Secret**. All three Twingate values are needed to start the connector; tokens are removed from nginx's and WeeChat's environment |
| `TWINGATE_RESOURCE_HOST`    | `weechat.internal` | Resource hostname, mapped to the container's IPv4 in `/etc/hosts` on every start |
| `TZ`                         | UTC             | Time zone for timestamps and log files, e.g. `Asia/Ho_Chi_Minh` |

Build argument: `GLOWING_BEAR_REF` (default `latest`) selects the Glowing
Bear release tag bundled in the image. It's only installed on a volume that
doesn't have Glowing Bear yet.

## Twingate setup

The connector and its isolated glibc libraries use the setup from
[soju-fly](../soju-fly). For Northflank, the Resource uses a hostname, as in
[soju-nf](../soju-nf): the container can't add Fly's fixed loopback IP, and
its own IPv4 changes on restart. The entrypoint maps `weechat.internal` to
that IPv4 in `/etc/hosts`; the connector reads it using `hosts: files dns`
in `/etc/nsswitch.conf`. nginx listens on all IPv4 addresses.

In the Twingate admin console:

1. Add a Remote Network for this container (e.g. `weechat-northflank`), then
   a connector in it. Choose Docker and generate its access and refresh
   tokens. Use a separate Remote Network: this connector's Resource name
   resolves to its own container.
2. Add a Resource with address `weechat.internal`, restrict it to TCP port
   `8080`, and give your group access. If that name is already used in your
   Twingate account, choose another and set `TWINGATE_RESOURCE_HOST` to match.
3. Add the network name and tokens to the service's environment as below.

With the Twingate client connected, open `http://weechat.internal:8080`.
Use the browser's system resolver: disable browser secure DNS (DoH) if the
private name fails to resolve. HTTP and WebSocket traffic travel inside the
encrypted Twingate tunnel.

The startup log shows `Twingate Resource weechat.internal is <ip>`, then
`Starting the Twingate connector for network ...` and the connector's
`State: Online`. Run `connectorctl health` in the container shell to check
it. The connector runs as `twingate` and restarts 5 seconds after it exits;
WeeChat stays the main process.

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
  - (optional) **Build arguments:** `GLOWING_BEAR_REF` to pin a release tag
- **Resources:** the smallest compute plan is enough. **Instances: 1**;
  additional instances would share the connector tokens and WeeChat volume.

### 4. Networking

Northflank reads `EXPOSE` from the Dockerfile. Check the **Ports** section:

| Port | Protocol | Public |
| ---- | -------- | ------ |
| 8080 | HTTP     | **No** — reached through Twingate |

If 8080 wasn't detected, add it by hand as **HTTP**. Turn off **Publicly
expose this port to the internet**, including on an existing service.
Twingate and the health check do not need a public port.

### 5. Environment variables

Under **Environment variables** (runtime), add as **secrets**:

```
WEECHAT_RELAY_PASSWORD=<a long random password>
WEECHAT_BACKUP_REMOTE=tigris:skypiea/weechat/
TWINGATE_NETWORK=<network>
TWINGATE_ACCESS_TOKEN=<access token>
TWINGATE_REFRESH_TOKEN=<refresh token>
TZ=America/Los_Angeles
```

Generate a password with e.g. `openssl rand -base64 24`.

Click **Create service**. The build takes a minute or two.

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

With the Twingate client connected, open `http://weechat.internal:8080`.
On the Glowing Bear login page:

- **Host:** `weechat.internal` (the path defaults to `api`)
- **Port:** `8080`
- **Password:** `WEECHAT_RELAY_PASSWORD`
- **TLS:** off (Twingate encrypts the tunnel)

Click **Connect**. To prefill the form, bookmark
`http://weechat.internal:8080/#host=weechat.internal&port=8080&autoconnect=true`.

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

### 10. Lua scripts

```
/plugin load lua
```

Only the Lua interpreter is installed, and automatic loading is disabled.
Keep Lua scripts in `/data/weechat/lua` and load them with `/lua load <file>`.
They survive redeploys. Python and Perl scripts are unavailable.

### Updating

- Pushing to `main` triggers a rebuild and redeploy automatically.
- To pick up new WeeChat or Alpine versions without changing this repo,
  start a new build manually from the service's **Builds** tab.
- Rebuilds also pick up the latest `1.x` Twingate connector.
- Glowing Bear is updated from a shell instead (see
  [Updating Glowing Bear](#updating-glowing-bear)). A new image doesn't
  replace the copy on the volume.
- Config and logs live on the volume and survive redeploys.

### Backups

From the volume's page, take a backup or set up scheduled backups.
Everything lives in `/data`.

The container also runs `/data/backup-weechat.sh` daily at 03:00 in the
container's time zone (`TZ`, UTC by default), using BusyBox `crond`. The
entrypoint copies this script to `/data` on every start; run it manually
from a container shell whenever needed.

Set the required `WEECHAT_BACKUP_REMOTE` environment variable to the upload
destination, for example `tigris:skypiea/weechat/`, and put the matching
rclone config at `/data/rclone.conf`. There is no default destination.
Each run recursively deletes all `*.zst` files under `/data/weechat`, creates
`/data/weechat.tar.gz` containing only regular `*.conf` files from that
directory and its subdirectories, including the `weechat/` folder level
(for example, `weechat/weechat.conf`), then uploads it:

```sh
rclone --config /data/rclone.conf copy /data/weechat.tar.gz "$WEECHAT_BACKUP_REMOTE"
```

Both extension filters are case-insensitive, so `*.CONF` and `*.ZST` also match.

The archive is deleted after a successful upload and kept if the upload
fails. Job output goes to the container logs. `DATA_DIR` and `WEECHAT_HOME`
overrides also apply to the backup script.

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

### Relay connection refused / HTTP 502

If nginx reports `connect() failed (111: Connection refused)` for
`127.0.0.1:9001`, the relay listener is unavailable. A volume from the older
terminal-only setup may still have relay autoload disabled. This image loads
the plugin explicitly on startup; rebuild and redeploy to apply the fix.

To recover a running container immediately, use its shell:

```sh
weechat-cmd '/plugin load relay'
weechat-cmd '/set relay.network.bind_address "127.0.0.1"'
weechat-cmd '/set relay.network.ipv6 off'
weechat-cmd '/set relay.network.password "${raw:${env:WEECHAT_RELAY_PASSWORD}}"'
weechat-cmd '/set relay.network.totp_secret ""'
weechat-cmd '/set relay.network.password_hash_iterations 1000'
weechat-cmd '/mute /relay del weechat'
weechat-cmd '/set relay.port.api 9001'
weechat-cmd '/save'
```

Then reconnect Glowing Bear. `/set relay.port.api 9001` creates or updates
the API relay when the relay plugin is loaded.

## Updating Glowing Bear

Glowing Bear is served from `/data/glowing-bear`. On the first start the
entrypoint copies the release bundled in the image there, and on every start
it copies `update-glowing-bear.sh` to `/data`. To switch to another release of
[pbtrung/glowing-bear] without a new image, open a shell on the container and
run:

```sh
/data/update-glowing-bear.sh           # latest release
/data/update-glowing-bear.sh v0.999.0  # a specific release tag
FORCE=1 /data/update-glowing-bear.sh   # reinstall even if already installed
```

It downloads the release's `.zip` asset, unpacks it next to the current copy
and swaps the two directories, so nginx never serves a half-installed tree.
The installed tag is in `/data/glowing-bear/.version`. Reload Glowing Bear in
the browser afterwards. No restart is needed.

## Run locally

```sh
docker build -t weechat weechat-nf/
docker run --rm -p 8080:8080 -v weechat-data:/data \
  -e WEECHAT_RELAY_PASSWORD=changeme \
  -e WEECHAT_BACKUP_REMOTE=tigris:skypiea/weechat/ \
  weechat
```

Then open http://localhost:8080 and connect to host `localhost`, port `8080`,
password `changeme`, **TLS off**.
Without the three Twingate variables, the connector stays off.

## Notes

- **Other relay clients** must speak the `api` relay protocol, e.g. WeeChat
  itself with `/remote add <name> http://weechat.internal:8080 -password=<password>`
  through Twingate.
  Clients that only speak the older `weechat` protocol (upstream Glowing
  Bear, WeeChat Android) can't connect. The relay's own TCP port is
  loopback-only.
- nginx allows 20 relay requests per minute per client IP (burst 10) to slow
  down password guessing. One Glowing Bear login takes 2–3 requests. Through
  Twingate, clients share the connector's address, so these limits apply to
  all Twingate users together.
- Glowing Bear stores its settings (and the password, if you tick **Save
  password**) in the browser's local storage.
- `WEECHAT_EXTRA_COMMANDS` runs on every start, so a setting it changes can't
  be changed permanently from Glowing Bear. Use it only for settings you want
  pinned.

[WeeChat]: https://weechat.org/
[WeeChat user's guide]: https://weechat.org/doc/
[Glowing Bear]: https://github.com/glowing-bear/glowing-bear
[pbtrung/glowing-bear]: https://github.com/pbtrung/glowing-bear
[WeeChat privacy gist]: https://gist.github.com/atoponce/f19666d6b206a10b411b97381a1861a1
[Twingate connector]: https://www.twingate.com/docs/connectors
