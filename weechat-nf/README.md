# WeeChat + ttyd-rs + tmux on Northflank, behind Twingate

A single container image running curses [WeeChat](https://weechat.org/) in
[tmux](https://github.com/tmux/tmux), with browser access through a source build
of [pbtrung/ttyd-rs](https://github.com/pbtrung/ttyd-rs). nginx proxies the web
terminal and provides `/healthz`. The Twingate connector keeps access private.
Interactive shells use zsh with Alpine’s `grml-zsh-config` package.

```text
browser ──Twingate──▶ connector ──▶ weechat.internal:8080 nginx
                                    ├─ /         ttyd-rs 127.0.0.1:7681
                                    │              └─ tmux session: weechat
                                    │                   ├─ WeeChat (curses)
                                    │                   └─ zsh (grml config)
                                    └─ /healthz  ttyd-rs /api/health
WeeChat ──▶ IRC networks (outbound only)
```

WeeChat starts immediately and stays connected when browsers disconnect.
Each browser attaches a tmux client to the same session. Reconnecting shows
the running terminal. The WeeChat relay and Glowing Bear are removed.

## Files

| File | Purpose |
| ---- | ------- |
| `Dockerfile` | Builds ttyd-rs from pinned source, copies the Twingate connector and isolated glibc libraries, installs the Alpine edge runtime |
| `ttyd-rs-musl.patch` | Uses the Linux `close_range` syscall directly because the Rust libc wrapper is unavailable on musl |
| `entrypoint.sh` | Applies WeeChat settings, starts tmux, ttyd-rs, nginx, cron and Twingate, supervises services and handles shutdown |
| `start-weechat.sh` | Starts curses WeeChat with mimalloc and the configured plugins |
| `ttyd-rs.toml` | Loopback listener, tmux attach command, browser session settings and disabled file transfer |
| `tmux.conf` | zsh default shell, terminal type, mouse disabled and window numbering |
| `nginx.conf` | Private port 8080, HTTP/WebSocket proxy and `/healthz` |
| `weechat-attach` | Attaches to tmux as the WeeChat user from a container terminal |
| `weechat-cmd` | Sends commands or buffer text through WeeChat’s FIFO |
| `backup-weechat.sh` | Daily rclone config backup and compressed-log cleanup |

## Environment variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `TTYD_PASSWORD` | **Required** | Password for the browser terminal; hashed with Argon2id at startup |
| `TTYD_USERNAME` | `weechat` | Browser terminal username |
| `WEECHAT_BACKUP_REMOTE` | **Required** | rclone destination, e.g. `tigris:skypiea/weechat/` |
| `WEECHAT_EXTRA_COMMANDS` | — | WeeChat commands run on every start, separated by `;` |
| `DATA_DIR` | `/data` | Persistent volume mount point |
| `WEECHAT_HOME` | `$DATA_DIR/weechat` | WeeChat config, logs, scripts and FIFO |
| `TWINGATE_NETWORK` | — | Network name in `<network>.twingate.com` |
| `TWINGATE_ACCESS_TOKEN` | — | Connector access token; secret |
| `TWINGATE_REFRESH_TOKEN` | — | Connector refresh token; secret |
| `TWINGATE_RESOURCE_HOST` | `weechat.internal` | Resource hostname mapped to the container’s current IPv4 |
| `TZ` | UTC | Time zone for logs and the backup schedule |

All three Twingate network/token values are needed to enable the connector.
Tokens are removed from the environment before starting tmux, WeeChat,
nginx, ttyd-rs and cron. The terminal password is hashed before starting
services; only the hash is passed to ttyd-rs. File transfer is disabled.

Build argument `TTYD_RS_REF` selects a ttyd-rs commit, tag or branch. The
default is `a10f6739e8b94e21ecc775bfa8dd4bb62e1f90ff`. The committed browser
assets are embedded by Cargo, so no Node build is needed. Other refs must
remain compatible with the musl patch and runtime configuration.

## Deploy on Northflank

1. Create a combined service from this repository, using Dockerfile
   `/weechat-nf/Dockerfile` and build context `/weechat-nf`. Run **one instance**.
2. Keep port **8080 HTTP private**. Disable public exposure on existing
   services as well.
3. Mount a persistent volume at **`/data`**. WeeChat data stays in
   `/data/weechat`; zsh startup files, history and cache live in `/data/home`.
4. Add runtime variables, marking passwords and connector tokens as secrets:

   ```text
   TTYD_PASSWORD=<a long random password>
   WEECHAT_BACKUP_REMOTE=tigris:skypiea/weechat/
   TWINGATE_NETWORK=<network>
   TWINGATE_ACCESS_TOKEN=<access token>
   TWINGATE_REFRESH_TOKEN=<refresh token>
   TZ=America/Los_Angeles
   ```

5. Put the matching rclone configuration at `/data/rclone.conf`.
6. Configure HTTP readiness/liveness checks on port **8080**, path
   **`/healthz`**. nginx forwards this to ttyd-rs; an unavailable ttyd-rs
   produces a failed check. WeeChat exits also stop the container.

The entrypoint runs under tini with `-s` so it also reaps orphaned children
when Northflank starts it behind another process. It supervises WeeChat,
ttyd-rs, nginx and cron. If one exits, the container stops so Northflank can
restart it. On SIGTERM, the entrypoint signals WeeChat to save its
configuration, closes tmux and stops the other services.

### Twingate

The connector and isolated glibc libraries follow [soju-fly](../soju-fly).
The hostname mapping follows [soju-nf](../soju-nf): on each start the
entrypoint maps the Resource hostname to the container’s current IPv4 in
`/etc/hosts`, with `hosts: files dns` in `/etc/nsswitch.conf`.

In the Twingate admin console:

1. Create a separate Remote Network for this service and a connector in it.
   Generate the connector access and refresh tokens.
2. Add a Resource with address **`weechat.internal`**, restricted to
   **TCP 8080**, and grant your group access. If you use another hostname,
   set `TWINGATE_RESOURCE_HOST` to match.
3. Set the three Twingate variables on the service.

Connect the Twingate client, open **http://weechat.internal:8080**, and log
in to ttyd-rs with username `weechat` and `TTYD_PASSWORD`. HTTP and WebSocket
traffic travel through the encrypted Twingate tunnel. If the private name
fails to resolve, disable browser secure DNS (DoH) so it uses the system
resolver.

The connector runs as `twingate` and restarts five seconds after an exit.
Check it from a container shell with `connectorctl health`.

## Using the terminal

The tmux session starts with window **1: weechat** and **2: shell**.

- Switch windows with **Ctrl-b, 1** or **Ctrl-b, 2**.
- Create another zsh window with **Ctrl-b, c**.
- Detach with **Ctrl-b, d**, or close the browser. WeeChat continues running.
- Attach from a Northflank terminal with `weechat-attach`, or locally with
  `docker exec -it <container> weechat-attach`.

zsh loads the grml configuration from `/etc/zsh/zshrc.d/grml-zsh-config.zsh`.
Put personal adjustments in `/data/home/.zshrc.local`; your own `.zshrc`
and `.zshenv` can also live in `/data/home`.

### Add an IRC network

In the WeeChat window:

```text
/server add libera irc.libera.chat/6697 -tls
/set irc.server.libera.nicks "yournick,yournick_"
/set irc.server.libera.sasl_mechanism plain
/set irc.server.libera.sasl_username "yournick"
/secure set libera <nickserv-password>
/set irc.server.libera.sasl_password "${sec.data.libera}"
/set irc.server.libera.autoconnect on
/connect libera
/join #weechat
/save
```

Channels joined or parted are remembered through `autojoin_dynamic`.

Commands can also be sent from a container shell:

```sh
weechat-cmd '/connect libera'
weechat-cmd 'irc.libera.#weechat' 'hello from the shell'
```

Command output appears in WeeChat’s buffers. Edit config files only while
WeeChat is stopped, or run `weechat-cmd '/reload'` afterwards.

## WeeChat defaults

On the first start only, the entrypoint sets:

- Log rotation at 10 MB, zstd compression at level 50.
- IRC smart filtering to hide join/part/quit from inactive speakers.
- `irc.server_default.autojoin_dynamic` on.
- Empty CTCP replies and part/quit messages, following the
  [WeeChat privacy gist](https://gist.github.com/atoponce/f19666d6b206a10b411b97381a1861a1).
- A stable FIFO at `${weechat_runtime_dir}/weechat_fifo` for `weechat-cmd`.

On every start, history is limited to 500 lines per buffer. The relay,
scripting plugins and DCC (`xfer`) are excluded both from startup plugin
loading and saved autoload settings, including on existing volumes.
Only the Lua interpreter is installed; load it explicitly with
`/plugin load lua`, then `/lua load <file>`. Lua scripts live in
`/data/weechat/lua` and survive redeploys.

WeeChat uses mimalloc via `LD_PRELOAD=/usr/lib/libmimalloc.so.3`. Additional
commands in `WEECHAT_EXTRA_COMMANDS` run on every start, followed by `/save`.
See the [WeeChat documentation](https://weechat.org/doc/) for all options.

## Backups

The container copies `backup-weechat.sh` to `/data` on every start and runs
it daily at **03:00** in `TZ` using BusyBox crond. Job output goes to the
container logs. Run `/data/backup-weechat.sh` manually when needed.

Each run removes all `*.zst` files below `WEECHAT_HOME`, then creates
`/data/weechat.tar.gz` containing only regular `*.conf` files, recursively,
including the `weechat/` folder level. Extension matching is case-insensitive.
It uploads using:

```sh
rclone --config /data/rclone.conf copy /data/weechat.tar.gz "$WEECHAT_BACKUP_REMOTE"
```

The archive is deleted after a successful upload and retained on failure.
`DATA_DIR` and `WEECHAT_HOME` overrides apply. Use Northflank volume backups
if you also need logs, scripts, zsh settings or other files under `/data`.

## Updating and migration

- Rebuild and redeploy to update the image; set `TTYD_RS_REF` to select a
  newer ttyd-rs revision. Alpine edge packages and Twingate `1.x` are picked
  up by uncached rebuilds.
- When migrating from the previous image, replace `WEECHAT_RELAY_PASSWORD`
  with **`TTYD_PASSWORD`**, and remove the `GLOWING_BEAR_REF` build argument.
  Existing WeeChat config, logs, scripts and backups remain in place.
- The relay plugin stays disabled even if an old `relay.conf` is on the
  volume. Old Glowing Bear files on the volume are unused and may be removed
  manually.
- Keep the existing private port 8080, Twingate Resource and `/healthz` check.

## Run locally

```sh
docker build -t weechat weechat-nf/
docker run --rm --name weechat -p 127.0.0.1:8080:8080 \
  -v weechat-data:/data \
  -e TTYD_PASSWORD=changeme \
  -e WEECHAT_BACKUP_REMOTE=tigris:skypiea/weechat/ \
  weechat
```

Open http://localhost:8080 and log in as `weechat` with password `changeme`.
Without the three Twingate variables, the connector stays off.
