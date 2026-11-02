# WeeChat headless + Glowing Bear on Northflank

WeeChat runs headless as `soju` (UID/GID 1000), using `/data/weechat` and
musl's allocator (mimalloc is opt-in, see `WEECHAT_MALLOC`). Nginx serves the bundled Glowing Bear
web client and proxies its HTTP/WebSocket API to WeeChat on `127.0.0.1:9001`.
Administration is available through Northflank’s container shell or
socket-activated telnet on private port 23. Tmux is not installed.

Mount the existing persistent volume at `/data`; existing WeeChat configs are
preserved. Startup grants soju read/write access to the volume and seeds
Glowing Bear into `/data/glowing-bear` only if `index.html` is missing.
Nginx workers run as soju so they can read the web client on that volume.

| Runtime variable | Purpose |
| --- | --- |
| `TELNET_USERNAME` | Required non-root telnet login name |
| `TELNET_PASSWORD` | Required secret telnet password, applied on every start |
| `WEECHAT_RELAY_PASSWORD` | Required secret for Glowing Bear login |
| `WEECHAT_HOME` | Config/backup directory, default `/data/weechat` |
| `WEECHAT_BACKUP_REMOTE` | rclone destination; enables daily 03:00 backup when set |
| `TWINGATE_NETWORK` | Required Twingate network name |
| `TWINGATE_ACCESS_TOKEN` | Required secret connector token |
| `TWINGATE_REFRESH_TOKEN` | Required secret connector token |
| `TWINGATE_RESOURCE_HOST` | Resource hostname, default `soju.internal` |
| `TZ` | WeeChat and cron time zone, default `UTC` |
| `WEECHAT_EXTRA_COMMANDS` | Optional additional WeeChat startup commands |
| `WEECHAT_MALLOC` | `musl` (default) or `mimalloc`: preloads mimalloc with `MIMALLOC_PURGE_DELAY=0` |

Set `WEECHAT_RELAY_PASSWORD` before deploying this change. It is passed only
to WeeChat; the relay config stores the environment reference instead of the
literal password. Connector tokens are not passed to WeeChat, nginx, or cron. Do not print environment variables or private config files.

Build with `/soju-nf/Dockerfile`, context `/soju-nf`, one instance. Build arguments
`TWINGATE_REF` and `GLOWING_BEAR_REF` default to `latest`. The latter selects the
`pbtrung/glowing-bear` release installed into the image. WeeChat with Lua,
mimalloc3, nginx, rclone, and the administration tools are installed from Alpine.
Lua remains available but interpreter plugins and xfer are not autoloaded.
Existing plugin autoload lists are updated; relay and FIFO are loaded explicitly.
The headless process starts with scripts/interpreters/xfer excluded as well.

To keep memory down, every start also excludes the plugins a headless
instance doesn't need (`spell`, `buflist`, `fset`, `script`, `typing`,
`exec`), keeping `irc`, `relay`, `logger`, `fifo`, `trigger`, `alias` and
`charset`; keeps 200 lines per buffer
(`weechat.history.max_buffer_lines_number`, older lines stay in the logs);
and sets `logger.look.backlog 0`, so opening a buffer doesn't load log lines
into memory. The default allocator is musl's, which keeps less memory
resident for a long-running, mostly idle process than mimalloc. Set
`WEECHAT_MALLOC=mimalloc` to preload mimalloc instead (with
`MIMALLOC_PURGE_DELAY=0`, returning freed memory right away) and compare.

Keep ports **8080 and 23 private**. In Twingate, allow port 8080 on the
`soju.internal` Resource for the web client, and TCP port 23 for telnet.
Startup maps the hostname to the current container IPv4 address. Open:

```
http://soju.internal:8080
```

Use `WEECHAT_RELAY_PASSWORD` for the Glowing Bear connection. Nginx forwards
`/api` to the loopback relay (API protocol, port 9001, IPv4 only). The relay port
is not exposed. Glowing Bear's API relay does not use a TOTP secret. Existing
relay settings are applied on every start. First-start defaults retain the
previous privacy settings, smart filtering, automatic channel persistence,
10 MB zstd log rotation, and empty CTCP/PART/QUIT replies.

Nginx also serves **`/healthz`** with HTTP 200 and `ok`. Configure Northflank's
HTTP probe on port **8080**, path **`/healthz`**, interval 30s, timeout 10s,
startup grace 60s, and failure threshold 3. This checks nginx; it does not
check the relay or Twingate. The Dockerfile probes the same endpoint.
`connectorctl health` separately checks Twingate. Nginx, WeeChat, inetd, Twingate, and enabled cron are supervised; an exit stops the container for
the platform to restart it. Shutdown is forwarded to WeeChat for config saves.
Tini uses subreaper mode. The platform controls the actual kernel hostname;
`/etc/hostname` remains `soju`.

For administration, open the Northflank container shell or connect through
Twingate with `telnet soju.internal 23`, using `TELNET_USERNAME` and
`TELNET_PASSWORD`. Both values are required at startup. Choose a lowercase
username starting with a letter or underscore, at most 32 characters, using
letters, digits, underscores or hyphens. Existing system account names are
rejected except `soju`.

A custom login is an alias for non-root service UID/GID 1000, with `/data` as
its home and full access to the same private files as WeeChat. Commands such
as `whoami` may show `soju` because both names identify the same UID.
Telnet sessions receive a clean environment without deployment secrets.
Startup runs as root on a volume this login can write, so it never writes
through a symbolic link there: it refuses a linked `WEECHAT_HOME`, replaces
a linked `/data/glowing-bear` with the bundled copy, changes owners with
`chown -h`, and installs `backup-weechat.sh` and `update-glowing-bear.sh`
as fresh copies.
Passwords are applied each start and then removed from the startup environment.
Telnet carries plaintext credentials inside Twingate’s encrypted tunnel; keep
port 23 private. `TERM` defaults to `xterm` when unset or `dumb`. No tmux is added.
Use `weechat-cmd` to send a command through
the running client's FIFO, without starting a second WeeChat on the same config:

```sh
weechat-cmd '/save'
/data/backup-weechat.sh
```

Update the web client from a shell without rebuilding the image:

```sh
/data/update-glowing-bear.sh          # latest release
/data/update-glowing-bear.sh TAG      # chosen release
```

Private source configs, converted configs, and local archives remain excluded
from Git and Docker build contexts. No private data is bundled into the image.

Daily backups use `backup-weechat.sh`, restored from commit `84699d2`.
Place the rclone config at `/data/rclone.conf` and set `WEECHAT_BACKUP_REMOTE`
to your remote destination. At 03:00 in `TZ`, the job runs as `soju`, deletes
rotated `*.zst` logs, archives only `*.conf` files under `WEECHAT_HOME` (including
the containing directory), and uploads `weechat.tar.gz`. The local archive is
removed after a successful upload. Cron and backup output go to container logs.
Startup saves the backup destination and WeeChat directory as literal values in
`/run/soju-backup` (root-owned, readable by `soju`). Both cron and manual runs
read these settings without inheriting deployment secrets. Restart the service
after changing its backup environment variables. An explicit environment value
on a manual invocation overrides the saved value.

The script is also available at `/data/backup-weechat.sh`; to run manually after
configuring `WEECHAT_BACKUP_REMOTE` on the service:

```sh
/data/backup-weechat.sh
```
