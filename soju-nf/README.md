# WeeChat headless + Glowing Bear on Northflank

WeeChat runs headless as `soju` (UID/GID 1000), using `/data/weechat` and
musl's allocator (mimalloc is opt-in, see `WEECHAT_MALLOC`). Nginx serves the bundled Glowing Bear
web client and proxies its HTTP/WebSocket API to WeeChat on `127.0.0.1:9001`.
Administration is available through Northflank’s container shell or
socket-activated TinySSH on `127.0.0.1:22`. Tmux is not installed.

Mount the existing persistent volume at `/data`; existing WeeChat configs are
preserved. Startup grants soju read/write access to the volume and seeds
Glowing Bear into `/data/glowing-bear` only if `index.html` is missing.
Nginx workers run as soju so they can read the web client on that volume.

| Runtime variable | Purpose |
| --- | --- |
| `SSH_USERNAME` | SSH login name, default `soju`; custom names alias UID/GID 1000 |
| `SSH_PUBLIC_KEY` | Required Ed25519 public key for SSH login, replaced on every start |
| `WEECHAT_RELAY_PASSWORD` | Required secret for Glowing Bear login |
| `WEECHAT_HOME` | Config/backup directory, default `/data/weechat` |
| `WEECHAT_BACKUP_REMOTE` | rclone destination; enables daily 03:00 backup when set |
| `CF_TUNNEL_TOKEN` | Required secret token for a remotely managed Cloudflare Tunnel |
| `TZ` | WeeChat and cron time zone, default `UTC` |
| `WEECHAT_EXTRA_COMMANDS` | Optional additional WeeChat startup commands |
| `WEECHAT_MALLOC` | `musl` (default) or `mimalloc`: preloads mimalloc with `MIMALLOC_PURGE_DELAY=0` |

Set `WEECHAT_RELAY_PASSWORD` before deploying this change. It is passed only
to WeeChat; the relay config stores the environment reference instead of the
literal password. The tunnel token is not passed to WeeChat, nginx, or cron. Do not print environment variables or private config files.

Build with `/soju-nf/Dockerfile`, context `/soju-nf`, one instance. Build argument
`GLOWING_BEAR_REF` defaults to `latest` and selects the
`pbtrung/glowing-bear` release installed into the image. WeeChat with Lua,
mimalloc3, nginx, rclone, TinySSH, and the administration tools are installed
from Alpine. Cloudflared is downloaded from the official
[GitHub releases](https://github.com/cloudflare/cloudflared/releases) for the
Docker target architecture (`amd64` or `arm64`). Build argument `CLOUDFLARED_REF`
defaults to `latest`; set it to a release tag to select a specific version.
Automatic self-updates are disabled; rebuild the image to update cloudflared.
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

Keep port **8080 private** in Northflank; SSH binds only to `127.0.0.1:22`. Set `CF_TUNNEL_TOKEN` to the
remotely managed tunnel's token. In the Cloudflare dashboard, configure a
published application hostname pointing to `http://127.0.0.1:8080`, then open
`https://<your-hostname>` for Glowing Bear. Configure Cloudflare Access for
that hostname to restrict access. Tunnel ingress is managed in Cloudflare;
no local credentials or ingress config file is required.

Use distinct public hostnames for the two routes:

| Example public hostname | Tunnel service |
| --- | --- |
| `irc.example.com` | `http://127.0.0.1:8080` |
| `ssh.example.com` | `ssh://127.0.0.1:22` |

Each hostname needs a proxied DNS CNAME to `<TUNNEL_ID>.cfargotunnel.com`.
Verify the records in Cloudflare DNS and open `https://irc.example.com` in
your browser; the loopback service address is used only inside the container.
If the browser reports a DNS error, check resolution of the public hostname
before debugging nginx. See [Cloudflare's tunnel DNS documentation](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/).

Use `WEECHAT_RELAY_PASSWORD` for the Glowing Bear connection. Nginx forwards
`/api` to the loopback relay (API protocol, port 9001, IPv4 only). The relay port
is not exposed. Glowing Bear's API relay does not use a TOTP secret. Existing
relay settings are applied on every start. First-start defaults retain the
previous privacy settings, smart filtering, automatic channel persistence,
10 MB zstd log rotation, and empty CTCP/PART/QUIT replies.

Nginx also serves **`/healthz`** with HTTP 200 and `ok`. Configure Northflank's
HTTP probe on port **8080**, path **`/healthz`**, interval 30s, timeout 10s,
startup grace 60s, and failure threshold 3. This checks nginx; it does not
check the relay or Cloudflare Tunnel. The Dockerfile probes the same endpoint.
Cloudflared runs as its own non-root user with only the tunnel token in its
service environment. Nginx, WeeChat, inetd, cloudflared, and enabled cron are supervised; an exit stops the container for
the platform to restart it. Shutdown is forwarded to WeeChat for config saves.
Tini uses subreaper mode. The platform controls the actual kernel hostname;
`/etc/hostname` remains `soju`.

For administration, open the Northflank container shell or connect as `SSH_USERNAME`
through Cloudflare Access. Configure a separate SSH application hostname with
service `ssh://127.0.0.1:22` and an Access policy, then connect from your machine:

```sh
ssh -o 'ProxyCommand=cloudflared access ssh --hostname %h' <SSH_USERNAME>@<ssh-hostname>
```

Set `SSH_PUBLIC_KEY` to your complete `ssh-ed25519 AAAA... comment` public key.
TinySSH supports Ed25519 login keys without authorized_keys options. Startup
replaces `/data/.ssh/authorized_keys` with this key, with directory mode 700 and
file mode 600. The non-root login uses UID/GID 1000, `/data` as its home, and
has access to the same private files as WeeChat. Custom names must start with a
lowercase letter or underscore, contain only lowercase letters, digits,
underscores or hyphens, and be at most 32 characters. Existing system account
names are rejected. The `soju` service account and custom aliases share the
same home and authorized key. Password login is unavailable.
SSH sessions receive a clean environment without deployment secrets. BusyBox
inetd activates TinySSH per connection on IPv4 loopback only, providing the
listener behavior of `ListenStream=127.0.0.1:22` without systemd.
The TinySSH launcher redirects stderr to the container log because BusyBox
inetd otherwise sends diagnostics into the SSH stream, corrupting packets.

Host keys are generated at runtime in `/etc/tinyssh/sshkeydir` and reused on
container restarts. Replacing the container generates a new host identity;
verify its fingerprint through the Northflank shell before updating known_hosts.
No host private keys are stored on the volume writable by `soju`.
Startup refuses a linked `WEECHAT_HOME`, replaces a linked
`/data/glowing-bear` with the bundled copy, changes owners with `chown -h`, and
installs helper scripts as fresh copies. SSH authorization files are written
as `soju`, so links in the volume cannot redirect root's writes.
`TERM` defaults to `xterm` when unset or `dumb`. No tmux is added.
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
