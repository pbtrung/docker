# Irssi in tmux on Northflank

Startup runs Irssi as the non-root `soju` user in a detached tmux session with
an automatically assigned name. Irssi uses `/data/irssi` and
`LD_PRELOAD=/usr/lib/libmimalloc.so.3`. The image installs `irssi` without the
optional Perl package; no Irssi scripting engine or scripts are loaded.
Python is used only by the standalone migration and log-maintenance tools.

Telnet remains socket-activated through BusyBox inetd on private TCP port 23.
A persistent BusyBox HTTP server runs as `nobody` on private port 8080 and
serves `/healthz` (200, `ok`). The connector, inetd, HTTP server, and cron daemon
are supervised; if any exits, the container stops for Northflank to restart it.
Quitting Irssi closes its tmux window without restarting the container.

Mount `/data` as a persistent volume. It is soju's home (UID/GID 1000);
startup recursively assigns it to soju and grants owner read/write/traversal.
The bundled `.tmux.conf` is installed on every start with status and mouse off.
Login shells default to `TERM=xterm`; tmux supplies its own terminal type inside
panes. Tini runs with subreaper mode for platforms that put another process at
PID 1. Northflank controls the kernel hostname; set it to `soju` through the
runtime where supported. The image also sets `/etc/hostname` to `soju`.

Build with Dockerfile `/soju-nf/Dockerfile` and context `/soju-nf`, one instance.
Keep ports 23 and 8080 private. Configure Northflank's HTTP health check on
port **8080**, path **`/healthz`**: interval 30s, timeout 10s, grace 60s, failure
threshold 3. The image also defines that probe. This checks HTTP serving;
`connectorctl health` separately checks the connector.

| Runtime variable | Purpose |
| --- | --- |
| `SOJU_PASSWORD` | Required password for fixed login user `soju`, applied each start |
| `TWINGATE_NETWORK` | Required Twingate network name |
| `TWINGATE_ACCESS_TOKEN` | Required connector token (secret) |
| `TWINGATE_REFRESH_TOKEN` | Required connector token (secret) |
| `TWINGATE_RESOURCE_HOST` | Resource hostname, default `soju.internal` |
| `IRSSI_BACKUP_REMOTE` | rclone destination; uploads disabled if unset |
| `WEECHAT_BACKUP_REMOTE` | Legacy fallback for the Irssi backup destination |
| `TZ` | Cron and Irssi time zone, default `UTC` |

Build argument `TWINGATE_REF` selects the connector image (default `latest`).
Configure a Twingate Resource for `soju.internal` in this connector's Remote
Network, allow TCP port 23, and grant your group access. Startup maps that name
to the current container address. Login sessions, Irssi, HTTP, and cron do not
inherit connector tokens. Root and service accounts remain password locked.

```sh
telnet soju.internal 23
# Login as soju, then:
tmux a
# Detach with Ctrl-b, then d.
```

If you quit Irssi, restart from the login shell with:

```sh
tmux new-session -d /usr/local/bin/start-irssi.sh
tmux a
```

Telnet carries plaintext credentials inside the Twingate tunnel; keep it private.

## Private WeeChat migration

`convert-weechat.py` processes `irc.conf` locally without printing its values.
It never opens `sec.conf`, decrypts secrets, evaluates WeeChat expressions, or
executes connect commands. Supported mappings: server addresses and fallback
servers, TLS, nick/alternate nick, user/real name, server passwords, PLAIN or
EXTERNAL SASL, user modes, and autojoin channels with keys. TLS certificate
verification is always enabled. Only the primary address autoconnects.

Unsupported expressions, proxies, SASL mechanisms, connect commands, or
plaintext authentication disable affected autoconnects and produce a generic
review notice. Set these up manually in Irssi. WeeChat relay settings, plugin
configs, aliases, triggers, scripts, layouts, and history are not copied.

The local result is `soju-nf/irssi/config`, with owner-only permissions; the
source is unchanged. Local source configs, converted configs, and archives
are excluded from both Git and Docker builds. **They are not baked into the
image.** Copy the private result to the persistent volume's `/data/irssi/config`
before deployment, or leave the original source at `/data/weechat/irc.conf`:
startup converts it only when `/data/irssi/config` is missing. Existing Irssi
configs are never overwritten. If neither config exists, startup creates an
empty hardened config for manual setup. To convert manually:

```sh
python3 convert-weechat.py weechat irssi/config
```

`/data/irssi/startup` is a managed native Irssi command file, refreshed on every
container start. It enforces CTCP reply queue size zero, empty VERSION/USERINFO
replies and PART/QUIT messages, ignores incoming CTCPS/DCC/DCCMSGS, disables
DCC auto-get/resume and invite autojoin, and blocks the ordinary DCC, CTCP,
NCTCP, MIRCDCC, SCRIPT and EXEC commands with aliases. These are user-changeable
settings, not removal of Irssi's compiled DCC code or a sandbox against the
logged-in user. No file-transfer or proxy service is started.

See the [Irssi CTCP implementation](https://github.com/irssi/irssi/blob/1.4.5/src/irc/core/ctcp.c)
and [DCC ignore handling](https://github.com/irssi/irssi/blob/1.4.5/src/irc/dcc/dcc.c)
for the native reply suppression and ignore behavior.

## Backups and logs

Irssi logs messages/notices/actions to `/data/irssi/logs/<network>/<target>.log`
with mode 600. Hourly cron archives each active log after **six days** and empties
it in place, preserving the open inode Irssi writes to. Exactly one compressed
archive (`<target>.log.1.gz`) is kept per log and replaced at the next rotation.
Thus the active log and its previous six-day period are retained. Logs and
archives are excluded from backups. Copy/truncate has a small race where a
message written between the copy and truncation can be lost.
A `.rotation` timestamp alongside
each log tracks its six-day period independently of ongoing writes. The hourly
check may run up to one hour after the boundary. Maintenance also runs at startup,
even without a backup remote, and never touches configuration files.

Daily at **03:00** in `TZ`, `backup-irssi.sh` runs as `soju`, archives only
`irssi/config` and the managed `irssi/startup`, and uploads `irssi.tar.gz` with
rclone. Logs and old WeeChat files are excluded. Put your rclone config at
`/data/rclone.conf` and set `IRSSI_BACKUP_REMOTE`. The old
`WEECHAT_BACKUP_REMOTE` is accepted as a fallback. If unset, uploading is skipped.
Archives contain credentials, so choose a private remote. The temporary local
archive is removed after the upload attempt. Output does not expose remote
names or credentials. Run manually after setting the destination in your shell:

```sh
IRSSI_BACKUP_REMOTE=remote:bucket/path /data/backup-irssi.sh
```

Test with the installed Irssi and synthetic data only:

```sh
python3 -m unittest discover -s soju-nf/tests -v
```
