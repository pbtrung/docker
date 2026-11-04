# soju-rs + gamja on Northflank

Runs soju-rs with its SQLite message store, gamja served by lighttpd, and a
remotely managed Cloudflare Tunnel. TinySSH remains socket-activated on
`127.0.0.1:22`. Services run as `soju` (UID/GID 1000), except cloudflared,
which has its own non-root account.

Build with `/soju-nf/Dockerfile`, context `/soju-nf`, and one instance. Mount
persistent storage at `/data`. The image downloads static musl binaries from
[pbtrung/soju-rs releases](https://github.com/pbtrung/soju-rs/releases), verifies
`SHA256SUMS`, and installs gamja from
[pbtrung/gamja releases](https://github.com/pbtrung/gamja/releases).
`SOJU_REF`, `GAMJA_REF`, and `CLOUDFLARED_REF` build arguments default to
`latest`; set release tags to pin versions. Supported targets are amd64 and
arm64. Rebuild to update soju-rs and cloudflared; self-updates are disabled.

| Runtime variable | Purpose |
| --- | --- |
| `CF_TUNNEL_TOKEN` | Required remotely managed Cloudflare Tunnel token |
| `SSH_PUBLIC_KEY` | Required single bare Ed25519 login public key |
| `SSH_USERNAME` | SSH login name, default `soju`; aliases UID/GID 1000 |
| `SOJU_ADMIN_USER` | Bootstrap administrator, default `admin` |
| `SOJU_ADMIN_PASSWORD` | Set to create the administrator if absent; existing admin passwords are preserved |
| `SOJU_CONFIG_FILE` | Optional replacement config file |
| `SOJU_DATA_DIR` | Database directory for permissions and backups, default `/data/soju`; a custom config must use the same path |
| `SOJU_STARTUP_TIMEOUT` | Seconds to wait for the admin socket, default `1800`; `0` waits indefinitely |
| `GAMJA_DATA_DIR` | Persistent web-client directory, default `/data/gamja` |
| `GAMJA_CONFIG_JSON` | gamja config; default `{"server":{"auth":"mandatory","ping":30}}` |
| `SOJU_BACKUP_REMOTE` | rclone destination; enables automatic backups when set |
| `SOJU_BACKUP_CRON` | Backup schedule, default `0 3 * * *` |
| `RCLONE_CONFIG_FILE` | Default `/data/rclone.conf` |
| `TZ` | Service and cron time zone, default `UTC` |

This restores the previous soju deployment. An existing `/data/soju/main.db`
is reused with its users, networks, and history. WeeChat files are preserved
on the volume but are no longer used; WeeChat configuration is not converted.
Remove the old `WEECHAT_*` deployment variables and set `SOJU_ADMIN_PASSWORD`
if you need a new administrator. Log into gamja with a soju account.
The bootstrap refuses to overwrite an existing non-admin account or continue
if an admin status check fails.

The bundled config uses `message-store db`, five-day message expiry, and a
200-message CHATHISTORY limit. SQLite stores account data and messages in
`/data/soju/main.db`. The admin socket is `/run/soju/admin`; `soju` and
`sojuctl` wrappers automatically select `/etc/soju/config`. To administer:

```sh
sojuctl user status admin
```

Keep ports **8080 and 6667 private** in Northflank. Configure your existing
Cloudflare published application hostname to use `http://127.0.0.1:8080`.
Lighttpd serves gamja at `/`, its settings at `/config.json`, and proxies
`/socket` with WebSocket upgrades to soju on `127.0.0.1:8081`. The former
WeeChat `/api` endpoint is replaced by `/socket`. Configure Cloudflare Access
for the public hostname. Tunnel ingress remains managed in Cloudflare.
Plain IRC listens on port 6667 for private clients or an optional Cloudflare
TCP route. No TLS listener is bundled; use the private network or tunnel.

The existing SSH route remains `ssh://127.0.0.1:22` on a separate public
hostname. Connect through Cloudflare Access:

```sh
ssh -o 'ProxyCommand=cloudflared access ssh --hostname %h' <SSH_USERNAME>@<ssh-hostname>
```

Startup replaces `/data/.ssh/authorized_keys` with `SSH_PUBLIC_KEY`. Login
keys must be Ed25519 without authorized_keys options. Custom usernames must
start with a lowercase letter or underscore, contain only lowercase letters,
digits, underscores or hyphens, and be at most 32 characters. System account
names are rejected. SSH sessions receive a clean environment; login shells
load backup and gamja paths from `/etc/profile.d/soju-env.sh`. Host keys live
outside the volume at `/etc/tinyssh/sshkeydir` and change when the container
is replaced. No tmux is installed.

The Docker health check and Northflank probe use HTTP port **8080**, path
**`/healthz`**, interval 30s, timeout 10s, startup grace 60s, and failure
threshold 3. This checks lighttpd only. Startup waits for the soju admin socket
before starting the web server, tunnel, and SSH listener. An exit of soju,
lighttpd, cloudflared, inetd, or enabled cron stops the container; shutdown
forwards SIGTERM to all services. Tini acts as a subreaper.

Gamja is seeded into the volume if `index.html` is missing. Update it from
a login shell without rebuilding:

```sh
/data/update-gamja.sh       # latest
/data/update-gamja.sh TAG   # selected release
```

Backups use SQLite `.backup` to snapshot the live database, including WAL
contents, then upload the snapshot as `main.db` using rclone. Put the rclone
config at `/data/rclone.conf` and set `SOJU_BACKUP_REMOTE` to enable the daily
03:00 job. Settings are also saved as literal values in `/run/soju-backup`
for manual runs from a clean container shell:

```sh
/data/backup-soju.sh
```

Explicit backup environment values override the saved settings. Temporary
snapshots are private and removed after success or failure. Private source
configs and archives remain excluded from Git and Docker build contexts.
