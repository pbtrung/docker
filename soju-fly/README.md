# soju + gamja + nginx on Fly.io

The [soju-nf](../soju-nf) image adapted for [Fly.io]. It runs:

- [soju-rs] — Rust port of the [soju] IRC bouncer, static musl binaries
  from the latest [pbtrung/soju-rs release][soju-rs releases]
- [gamja] — IRC web client, prebuilt release from the [pbtrung/gamja] fork,
  kept on the volume so it can be updated from a shell
- nginx — serves gamja and proxies the IRC WebSocket (`/socket`) to soju
- [dnclient] — joins the machine to a [Defined Networking] (Managed Nebula)
  network. It replaces cloudflared, which soju-nf uses.

Nothing is exposed publicly: `fly.toml` has no service, so the Fly proxy
doesn't route any traffic to the machine. gamja and soju's plain IRC port are
only reachable from hosts on your Defined network (and from Fly's
private network).

File uploads (IRCv3 filehost) are disabled: soju-rs doesn't support them
and nginx doesn't proxy `/uploads`.

```
browser ───Nebula──▶ <nebula-ip>:8080 nginx ─┬─ /            gamja static files
                                             ├─ /config.json  gamja config
                                             ├─ /socket       ─▶ soju 127.0.0.1:8081 (WebSocket)
                                             └─ /healthz      200 ok (Fly health check)
IRC client ─Nebula──▶ <nebula-ip>:6667 soju plain IRC
```

Both ports also listen on Fly's private network (6PN), e.g.
`soju-ndq0bn8tgjuyd.internal:6667`, which `fly proxy` and `fly wireguard`
can reach.

Fly settings (`fly.toml`): app `soju-ndq0bn8tgjuyd`, region `iad`, one
`shared-cpu-1x` machine with 256 MB, no public service, and a 1 GB volume
`soju_data` at `/data`. It holds:

```
/data/
├── soju/main.db                 SQLite DB (SOJU_DATA_DIR)
├── gamja/                       gamja web client (GAMJA_DATA_DIR)
├── defined/                     dnclient state (DNCLIENT_STATE_DIR)
│   └── dnclient.yml             enrollment: host keys and Nebula config
└── update-gamja.sh              gamja updater, copied on every start
```

## Files

| File              | Purpose |
| ----------------- | ------- |
| `fly.toml`        | Fly app config: no public service, `/healthz` check, volume, VM size |
| `Dockerfile`      | `builder` stage downloads a soju-rs release (checked against its `SHA256SUMS`), a gamja release and a `dnclient` release from Defined Networking's [downloads]; runtime stage on alpine:edge installs nginx, rclone and sqlite with `apk` |
| `soju-wrapper.sh` | Installed as `soju` and `sojuctl`: runs the soju-rs binary with `-config /etc/soju/config` |
| `entrypoint.sh`   | Installs gamja on the volume, starts dnclient (enrolling it once), writes the soju config from env vars, creates the first admin, starts nginx then soju |
| `update-gamja.sh` | Installs a gamja release (latest, or a given tag) into `GAMJA_DATA_DIR` |
| `nginx.conf`      | Serves gamja, proxies `/socket`, `/healthz`, rate limits |

## Environment variables

Set plain values under `[env]` in `fly.toml`, and secrets with
`fly secrets set`.

| Variable              | Default                                     | Description |
| --------------------- | ------------------------------------------- | ----------- |
| `DN_ENROLLMENT_CODE`  | —                                           | Defined Networking enrollment code. **Secret.** Used only while `$DNCLIENT_STATE_DIR/dnclient.yml` doesn't exist |
| `DN_API_SERVER`       | `https://api.defined.net`                   | Defined Networking API server |
| `DNCLIENT_STATE_DIR`  | `/data/defined`                             | Where dnclient keeps its enrollment (instead of `/var/lib/defined`) |
| `SOJU_HOSTNAME`       | `soju`                                      | Server name shown to clients (gamja: "Connected to soju") |
| `SOJU_TITLE`          | —                                           | Server title shown to clients |
| `SOJU_ADMIN_USER`     | —                                           | Admin user created on first start (only while `/data/soju/main.db` doesn't exist) |
| `SOJU_ADMIN_PASSWORD` | —                                           | Password for that admin user. **Secret** |
| `SOJU_MESSAGE_EXPIRY` | `5d`                                        | Delete messages older than this (`<n>d`), on startup then daily, and vacuum the DB. `0d` keeps them forever |
| `SOJU_EXTRA_CONFIG`   | —                                           | Extra soju config lines appended as-is (e.g. `max-user-networks 5`) |
| `SOJU_CONFIG_FILE`    | —                                           | Path to a complete soju config. If set, the env vars above that build the config are ignored |
| `GAMJA_CONFIG_JSON`   | `{"server":{"auth":"mandatory","ping":30}}` | gamja [config file] contents, served at `/config.json` |
| `SOJU_DATA_DIR`       | `/data/soju`                                | Where the soju DB (`main.db`) is stored |
| `GAMJA_DATA_DIR`      | `/data/gamja`                               | Where gamja is installed; `update-gamja.sh` is copied to its parent directory |

Build arguments: `SOJU_REF` (default `latest`) selects the
[soju-rs release][soju-rs releases] to install (e.g. `v0.99.2`).
`GAMJA_REF` (default `latest`) selects the gamja release
bundled in the image, only installed on a volume without gamja.
`DNCLIENT_VERSION` (default `latest`) is
the dnclient version to download (e.g. `0.9.9`), looked up in
`https://api.defined.net/v1/downloads`.

The release metadata (GitHub's latest soju-rs and gamja releases, and the
dnclient downloads) is fetched with `ADD` on every build, so a new release
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
printf 'DN_ENROLLMENT_CODE=%s\n' '<enrollment code>' |
  fly secrets import -a soju-ndq0bn8tgjuyd --stage

# 3. Build and deploy a single machine
fly deploy --ha=false
```

`--stage` stores the secrets without restarting anything; the first deploy
picks them up. `fly secrets import` reads the code from standard input,
so it stays out of your shell history and process list.

Keep a single machine: the volume can only attach to one, and soju
can't run as several instances. To check, run `fly scale show`. If
there are more, run `fly scale count 1`. Without a service, the Fly proxy
never stops or starts the machine, and `[[restart]] policy = 'always'`
restarts it if soju exits.

The app has no service, so it needs no public IP. If `fly ips list` shows
any (the first deploy of an app with a service allocates them), you can
release them with `fly ips release <ip>`.

The image build runs on Fly's remote builder and only installs packages and
downloads releases.

### Log in

From a host on your Defined network, open `http://<nebula-ip>:8080` (see
[Defined Networking](#defined-networking)). gamja loads. Log in with
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

## Defined Networking

With `DN_ENROLLMENT_CODE` set, the entrypoint starts `dnclient run` in the
background and, on the first start only, enrolls the host with
`dnclient enroll -code`. dnclient's state lives in `/data/defined` (set with
`DNCLIENT_STATE_DIR` in the image) rather than its usual `/var/lib/defined`,
so it survives restarts and redeploys. Once `/data/defined/dnclient.yml`
exists, the code isn't used again: later starts only run the daemon, and
you can remove the secret with `fly secrets unset DN_ENROLLMENT_CODE`.

1. In the [Defined Networking admin panel][dn admin], add a host and copy
   its enrollment code (codes are single-use and expire).
2. Store it as a secret (see [Deploy](#deploy)) and deploy. The logs show
   `Enrolling with Defined Networking`; the host's Nebula IP is in the
   admin panel, or `fly ssh console -C 'dnclient info'`.
3. Allow ports 8080 and 6667 to the host in its role's firewall rules, then
   connect from another host on the network to `<nebula-ip>:6667` or
   `http://<nebula-ip>:8080`.

If enrollment fails (a bad or used code), the machine fails to start and Fly
restarts it. To enroll again (e.g. as another host), delete the state and
set a new code:

```sh
fly ssh console -C 'rm -rf /data/defined'
printf 'DN_ENROLLMENT_CODE=%s\n' '<new code>' | fly secrets import  # restarts the machine
```

Without `DN_ENROLLMENT_CODE` and without a saved `dnclient.yml`, dnclient
isn't started. gamja and IRC are then only reachable from Fly's private
network, e.g. `fly proxy 8080` then `http://localhost:8080`.

## Updating

- `fly deploy` rebuilds the image and picks up the latest soju-rs release
  and the latest `dnclient` (check `Starting soju-rs vX` in `fly logs`).
  The DB and the dnclient enrollment live
  on the volume and survive it. soju migrates its schema itself on startup.
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

soju deletes messages older than `SOJU_MESSAGE_EXPIRY` (5 days by default)
on startup and then daily, and vacuums the DB to give the space back to the
volume.

## Run locally

```sh
docker build -t soju-fly soju-fly/
docker run --rm -p 8080:8080 -v soju-data:/data \
  --cap-add NET_ADMIN \
  -e SOJU_ADMIN_USER=admin -e SOJU_ADMIN_PASSWORD=changeme \
  -e DN_ENROLLMENT_CODE=... \
  soju-fly
```

`--cap-add NET_ADMIN` is only needed with `DN_ENROLLMENT_CODE`, for
dnclient's tun interface.

## Notes

- nginx sees clients' own Nebula IPs and forwards them to soju as a
  single `X-Forwarded-For` address, which soju trusts from loopback
  (`accept-proxy-ip localhost`). Rate limits apply per client.
- gamja sends `PING` every 30 s by default (`GAMJA_CONFIG_JSON`) to keep
  its WebSocket open through NAT along the way.
- The machine never stops on its own: there's no service for the Fly proxy
  to auto-stop, and `[[restart]] policy = 'always'` restarts it if soju
  exits. Deploys stop it and start the new image on the same volume
  (`strategy = 'immediate'`), sending soju `SIGTERM` with 30 s to shut
  down cleanly. 512 MB of swap keeps a memory spike from OOM-killing soju
  on the 256 MB VM.
- gamja is served over plain HTTP. The Nebula tunnel encrypts the traffic
  in transit.

[Fly.io]: https://fly.io/
[soju]: https://soju.im/
[soju-rs]: https://github.com/pbtrung/soju-rs
[soju-rs releases]: https://github.com/pbtrung/soju-rs/releases
[gamja]: https://codeberg.org/emersion/gamja
[pbtrung/gamja]: https://github.com/pbtrung/gamja
[dnclient]: https://docs.defined.net/glossary/dnclient/
[Defined Networking]: https://www.defined.net/
[downloads]: https://www.defined.net/downloads/
[dn admin]: https://admin.defined.net/
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
