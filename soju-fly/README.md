# soju + gamja + nginx on Fly.io

The [soju-nf](../soju-nf) image adapted for [Fly.io]. It runs:

- [soju-rs] — Rust port of the [soju] IRC bouncer, static musl binaries
  from the latest [pbtrung/soju-rs release][soju-rs releases]
- [gamja] — IRC web client, prebuilt release from the [pbtrung/gamja] fork,
  kept on the volume so it can be updated from a shell
- nginx, one worker — only lets Cloudflare's IPs in (stream module),
  terminates HTTPS, serves gamja and proxies the IRC WebSocket (`/socket`)
  to soju

gamja is public at `https://soju.110000001.xyz`, through Cloudflare only.
The Fly proxy passes port 443 through as raw TCP, with a PROXY protocol
header carrying the real peer address. nginx's stream block first drops any peer that
isn't in [Cloudflare's IP ranges][cloudflare ips], before any TLS work,
then terminates TLS with a [Cloudflare Origin CA] cert and requires the
client cert of [Authenticated Origin Pulls] (AOP), which only Cloudflare
holds. soju's plain IRC
port is only reachable from Fly's private network.

File uploads (IRCv3 filehost) are disabled: soju-rs doesn't support them
and nginx doesn't proxy `/uploads`.

```
browser ─HTTPS─▶ Cloudflare ─HTTPS+AOP─▶ Fly :443 ─TCP+PROXY─▶ nginx stream :8443
  Cloudflare IPs only ─▶ nginx https 127.0.0.1:8444 (TLS + AOP) ─┬─ /            gamja static files
                                                                 ├─ /config.json  gamja config
                                                                 ├─ /socket       ─▶ soju 127.0.0.1:8081 (WebSocket)
                                                                 └─ /healthz      200 ok
Fly health check ──▶ nginx :8080 (same paths, plain HTTP)
IRC client ─6PN─▶ soju :6667 plain IRC
```

Ports 8080 and 6667 listen on Fly's private network (6PN), e.g.
`soju-ndq0bn8tgjuyd.internal:6667`, which `fly proxy` and `fly wireguard`
can reach.

Fly settings (`fly.toml`): app `soju-ndq0bn8tgjuyd`, region `iad`, one
`shared-cpu-1x` machine with 256 MB, one TCP service (443 → 8443), and a 1 GB volume
`soju_data` at `/data`. It holds:

```
/data/
├── soju/main.db                 SQLite DB (SOJU_DATA_DIR)
├── gamja/                       gamja web client (GAMJA_DATA_DIR)
└── update-gamja.sh              gamja updater, copied on every start
```

## Files

| File              | Purpose |
| ----------------- | ------- |
| `fly.toml`        | Fly app config: TCP service 443 → 8443, `/healthz` check, volume, VM size |
| `Dockerfile`      | `builder` stage downloads a soju-rs release (checked against its `SHA256SUMS`) and a gamja release; runtime stage on alpine:edge installs nginx (with the stream module), rclone and sqlite with `apk`; also fetches Cloudflare's IP ranges into `/etc/nginx/cloudflare-allow.conf` |
| `soju.conf`       | soju config, installed as `/etc/soju/config`: DB, message expiry, `chathistory-limit`, listeners, hostname |
| `soju-wrapper.sh` | Installed as `soju` and `sojuctl`: runs the soju-rs binary with `-config /etc/soju/config` |
| `entrypoint.sh`   | Installs gamja on the volume, writes the TLS certs from their secrets, uses `SOJU_CONFIG_FILE` as the soju config if set, creates the first admin, starts nginx then soju |
| `update-gamja.sh` | Installs a gamja release (latest, or a given tag) into `GAMJA_DATA_DIR` |
| `nginx.conf`      | One worker; plain HTTP server on 8080, per-IP limits; includes the stream filter and TLS server when enabled |
| `nginx-stream.conf` | Stream server on 8443: PROXY protocol, Cloudflare IP allow-list, passes the TLS stream to 127.0.0.1:8444 |
| `nginx-tls.conf`  | HTTPS server on 127.0.0.1:8444: Origin CA cert, AOP client cert check, client IP from `CF-Connecting-IP` |
| `gamja-locations.conf` | gamja, `/config.json`, `/socket` and `/healthz` locations, shared by both HTTP servers |

## Environment variables

Set plain values under `[env]` in `fly.toml`, and secrets with
`fly secrets set`.

| Variable              | Default                                     | Description |
| --------------------- | ------------------------------------------- | ----------- |
| `ORIGIN_CERT`         | —                                           | Cloudflare Origin CA cert (PEM or base64 of it). **Secret** |
| `ORIGIN_KEY`          | —                                           | Its private key (PEM or base64 of it). **Secret** |
| `CF_AOP_CA`           | —                                           | CA that signs Cloudflare's AOP client cert (PEM or base64 of it). **Secret**. HTTPS on 8443 is only enabled when all three are set |
| `SOJU_ADMIN_USER`     | —                                           | Admin user created on first start (only while `/data/soju/main.db` doesn't exist) |
| `SOJU_ADMIN_PASSWORD` | —                                           | Password for that admin user. **Secret** |
| `SOJU_CONFIG_FILE`    | —                                           | Path to a complete soju config to use instead of the bundled `soju.conf` |
| `GAMJA_CONFIG_JSON`   | `{"server":{"auth":"mandatory","ping":30}}` | gamja [config file] contents, served at `/config.json` |
| `SOJU_DATA_DIR`       | `/data/soju`                                | Where the soju DB (`main.db`) is stored. Must match the `db` path of the soju config |
| `GAMJA_DATA_DIR`      | `/data/gamja`                               | Where gamja is installed; `update-gamja.sh` is copied to its parent directory |

Build arguments: `SOJU_REF` (default `latest`) selects the
[soju-rs release][soju-rs releases] to install (e.g. `v0.99.2`).
`GAMJA_REF` (default `latest`) selects the gamja release
bundled in the image, only installed on a volume without gamja.

The release metadata (GitHub's latest soju-rs and gamja releases) is fetched with `ADD` on every build, so a new release
invalidates the cached download layers: "latest" really is the latest, even
with the build cache. The startup log shows the soju-rs version running
(`Starting soju-rs vX`).

## Deploy

Run these from this directory (`soju-fly/`), logged in with `fly auth login`.

```sh
# 1. App and volume
fly apps create soju-ndq0bn8tgjuyd
fly volumes create soju_data --region iad --size 1 -a soju-ndq0bn8tgjuyd

# 2. Secrets
fly secrets set -a soju-ndq0bn8tgjuyd --stage \
  SOJU_ADMIN_USER=admin \
  SOJU_ADMIN_PASSWORD='<a strong password>'
fly secrets set -a soju-ndq0bn8tgjuyd --stage \
  ORIGIN_CERT="$(cat cert.pem)" \
  ORIGIN_KEY="$(cat key.pem)" \
  CF_AOP_CA="$(cat rootca.crt)"

# 3. Build and deploy a single machine
fly deploy --ha=false
```

`--stage` stores the secrets without restarting anything; the first deploy
picks them up. The cert files are ignored by git and Docker: keep them out
of the repo and the image.

Keep a single machine: the volume can only attach to one, and soju
can't run as several instances. To check, run `fly scale show`. If
there are more, run `fly scale count 1`. There is no autoscaling (min = max
= 1): the service has `auto_stop_machines = 'off'` and
`auto_start_machines = false`, so the Fly proxy never stops or starts the
machine, and `[[restart]] policy = 'always'`
restarts it if soju exits.

### Cloudflare

The service is raw TCP (only the `proxy_proto` handler), which Fly only
routes on a dedicated IP: the shared IPv4 doesn't work. Use the dedicated IPv6
(`fly ips list`; `fly ips allocate-v6` if there is none). Cloudflare still
serves IPv4 visitors.

1. DNS: a proxied `AAAA` record `soju` → the app's dedicated IPv6, and no
   `A` record to the shared IPv4.
2. SSL/TLS mode: Full (strict). The Origin CA cert covers
   `soju.110000001.xyz`.
3. Authenticated Origin Pulls, per hostname: upload a client cert signed by
   `CF_AOP_CA` (`POST /zones/{zone_id}/origin_tls_client_auth/hostnames/certificates`),
   enable it for `soju.110000001.xyz`
   (`PUT /zones/{zone_id}/origin_tls_client_auth/hostnames`), and turn on
   AOP for the zone. Until then nginx answers Cloudflare with 400.

`curl -I https://soju.110000001.xyz/healthz` should return 200, and the
startup log shows `Enabling HTTPS on 8443 with the Cloudflare origin cert
and AOP`.

Cloudflare's IP ranges are baked into the image at build time: redeploy
(`fly deploy --ha=false`) when Cloudflare announces new ones.

The image build runs on Fly's remote builder and only installs packages and
downloads releases.

### Log in

Open `https://soju.110000001.xyz`. gamja loads. Log in with
`SOJU_ADMIN_USER` / `SOJU_ADMIN_PASSWORD`, then add an upstream network,
either in gamja's "add network" UI or with `BouncerServ`:

```
/msg BouncerServ network create -addr ircs://irc.libera.chat -name libera -nick yournick
/msg BouncerServ sasl set-plain -network libera yournick <nickserv-password>
```

`/msg BouncerServ help` lists every command. After the first start you can
remove the admin password: `fly secrets unset SOJU_ADMIN_PASSWORD`.

### Manage users

From gamja as an admin (`/msg BouncerServ user create -username bob -password <password>`),
or from a shell on the machine:

```sh
fly ssh console
sojuctl user create -username bob -password <password>
sojuctl user status
```

`sojuctl` already knows where the config is (`/etc/soju/config`). soju-rs
has no `sojudb`: the entrypoint creates the first admin with `sojuctl` over
the admin socket once soju is up.

## Updating

- `fly deploy` rebuilds the image and picks up the latest soju-rs release
  (check `Starting soju-rs vX` in `fly logs`). The DB lives on the
  volume and survives it. soju migrates its schema itself on startup.
- gamja is updated from a shell, not by a new image:

  ```sh
  fly ssh console -C /data/update-gamja.sh            # latest release
  fly ssh console -C '/data/update-gamja.sh v0.999.0' # a specific tag
  ```

  The script downloads the release's `.zip`, unpacks it next to the current
  copy and swaps the two directories, so nginx never serves a half-installed
  tree. Set `FORCE=1` to reinstall the same tag. Reload gamja in the browser
  afterwards. No restart is needed.

## Backups

Fly takes daily snapshots of the volume (`fly volumes snapshots list <volume-id>`).
To copy the DB out, first take a consistent copy with the `sqlite3` CLI
(soju keeps writing to `main.db` and its `-wal` file while it runs):

```sh
fly ssh console -C "sqlite3 /data/soju/main.db '.backup /tmp/main.db'"
fly ssh sftp get /tmp/main.db main.db
```

`sqlite3` also lets you inspect the DB from a shell, e.g.
`sqlite3 -readonly /data/soju/main.db '.tables'`.

## Message expiry

soju deletes messages older than `message-expiry` in `soju.conf` (5 days)
on startup and then daily, and vacuums the DB to give the space back to the
volume.

## History limit

`chathistory-limit 200` in `soju.conf` caps each CHATHISTORY reply at 200
messages: gamja loads the latest 200 lines of each buffer on connect (its
default), and fetches older or missed messages in more requests. This keeps
soju's memory down on the 256 MB machine while gamja loads every buffer.

## Run locally

```sh
docker build -t soju-fly soju-fly/
docker run --rm -p 8080:8080 -v soju-data:/data \
  -e SOJU_ADMIN_USER=admin -e SOJU_ADMIN_PASSWORD=changeme \
  soju-fly
```

gamja is then at `http://localhost:8080`. Without the cert secrets, HTTPS
on 8443 stays off.

## Notes

- On 8443, nginx takes the client's IP from `CF-Connecting-IP` (safe:
  only Cloudflare passes the IP filter and the AOP check) and sends it to
  soju as a single `X-Forwarded-For`, which soju trusts from loopback
  (`accept-proxy-ip localhost`). Any `Forwarded` header from a client is
  dropped, since soju prefers it.
- Per client IP: 60 requests per minute for gamja's files (burst 30) and
  20 concurrent connections; nginx closes the connection on a violation.
  One nginx worker with 256 connections and Fly's `hard_limit = 30` cap
  the totals.
- The service caps the machine at 30 concurrent TCP connections
  (`[services.concurrency]`, `hard_limit = 30`): the Fly proxy doesn't
  send it more. Each open gamja tab holds one WebSocket connection, so
  raise it if you have more users.
- gamja sends `PING` every 30 s by default (`GAMJA_CONFIG_JSON`) to keep
  its WebSocket open through Cloudflare (100 s idle timeout) and NAT.
- The machine never stops on its own: the service has auto-stop and
  auto-start off, and `[[restart]] policy = 'always'` restarts it if soju
  exits. Deploys stop it and start the new image on the same volume
  (`strategy = 'immediate'`), sending soju `SIGTERM` with 30 s to shut
  down cleanly. 512 MB of swap keeps a memory spike from OOM-killing soju
  on the 256 MB VM.
- Traffic is HTTPS end to end: visitor → Cloudflare (Cloudflare's edge
  cert) and Cloudflare → nginx (Origin CA cert). Port 8080 is plain HTTP
  but only on Fly's private network.

[Fly.io]: https://fly.io/
[soju]: https://soju.im/
[soju-rs]: https://github.com/pbtrung/soju-rs
[soju-rs releases]: https://github.com/pbtrung/soju-rs/releases
[gamja]: https://codeberg.org/emersion/gamja
[pbtrung/gamja]: https://github.com/pbtrung/gamja
[cloudflare ips]: https://www.cloudflare.com/ips/
[Cloudflare Origin CA]: https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/
[Authenticated Origin Pulls]: https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
