# soju + gamja + nginx on Fly.io

The [soju-nf](../soju-nf) image adapted for [Fly.io]. It runs:

- [soju] — IRC bouncer (Alpine edge `soju` package)
- [gamja] — IRC web client, prebuilt release from the [pbtrung/gamja] fork,
  kept on the volume so it can be updated from a shell
- nginx — serves gamja and proxies the IRC WebSocket (`/socket`) to soju
- [wgcf-mesh] — joins the machine to [Cloudflare Mesh] over WireGuard. It
  replaces cloudflared, which soju-nf uses.

Nothing is exposed publicly: `fly.toml` has no service, so the Fly proxy
doesn't route any traffic to the machine. gamja and soju's plain IRC port are
only reachable from devices on your Mesh (and from Fly's private network).

File uploads (IRCv3 filehost) are disabled: soju has no `file-upload`
backend and nginx doesn't proxy `/uploads`.

```
browser ───Cloudflare Mesh──▶ wg0 100.96.x.x:8080 nginx ─┬─ /            gamja static files
                                                          ├─ /config.json  gamja config
                                                          ├─ /socket       ─▶ soju 127.0.0.1:8081 (WebSocket)
                                                          └─ /healthz      200 ok (Fly health check)
IRC client ─Cloudflare Mesh──▶ wg0 100.96.x.x:6667 soju plain IRC
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
├── wgcf-mesh/                   Mesh registration (WGCF_MESH_DIR)
│   ├── wgcf-mesh-<id>.conf      WireGuard config, with the private key
│   └── wgcf-mesh-<id>.json      device profile, to delete the device later
└── update-gamja.sh              gamja updater, copied on every start
```

## Files

| File              | Purpose |
| ----------------- | ------- |
| `fly.toml`        | Fly app config: no public service, `/healthz` check, volume, VM size |
| `Dockerfile`      | `builder` stage downloads a gamja release and `wgcf-mesh.sh`; runtime stage on alpine:edge installs soju, nginx and wireguard-tools (`wg-quick`) with `apk` |
| `entrypoint.sh`   | Installs gamja on the volume, registers and brings up the Mesh, writes the soju config from env vars, creates the first admin, starts nginx then soju |
| `update-gamja.sh` | Installs a gamja release (latest, or a given tag) into `GAMJA_DATA_DIR` |
| `nginx.conf`      | Serves gamja, proxies `/socket`, `/healthz`, rate limits |

## Environment variables

Set plain values under `[env]` in `fly.toml`, and secrets with
`fly secrets set`.

| Variable              | Default                                     | Description |
| --------------------- | ------------------------------------------- | ----------- |
| `WGCF_MESH_TOKEN`     | —                                           | Cloudflare Mesh node token (`eyJhIjoi…`). **Secret.** Used only while no config is saved in `WGCF_MESH_DIR` |
| `WGCF_MESH_NAME`      | `$FLY_APP_NAME`                             | Device name shown in the Cloudflare dashboard, set at registration |
| `WGCF_MESH_ROUTES`    | `100.96.0.0/12`                             | Space- or comma-separated CIDRs sent through the tunnel (the `AllowedIPs` given to wg-quick) |
| `WGCF_MESH_DIR`       | `/data/wgcf-mesh`                           | Where the Mesh config and device profile are kept |
| `SOJU_HOSTNAME`       | `soju`                                      | Server name shown to clients (gamja: "Connected to soju") |
| `SOJU_TITLE`          | —                                           | Server title shown to clients |
| `SOJU_ADMIN_USER`     | —                                           | Admin user created on first start (only while `/data/soju/main.db` doesn't exist) |
| `SOJU_ADMIN_PASSWORD` | —                                           | Password for that admin user. **Secret** |
| `SOJU_EXTRA_CONFIG`   | —                                           | Extra soju config lines appended as-is (e.g. `max-user-networks 5`) |
| `SOJU_CONFIG_FILE`    | —                                           | Path to a complete soju config. If set, the env vars above that build the config are ignored |
| `GAMJA_CONFIG_JSON`   | `{"server":{"auth":"mandatory","ping":30}}` | gamja [config file] contents, served at `/config.json` |
| `SOJU_DATA_DIR`       | `/data/soju`                                | Where the soju DB (`main.db`) is stored |
| `GAMJA_DATA_DIR`      | `/data/gamja`                               | Where gamja is installed; `update-gamja.sh` is copied to its parent directory |

Build arguments: `GAMJA_REF` (default `latest`) selects the gamja release
bundled in the image, only installed on a volume without gamja.
`WGCF_MESH_REF` (default `main`) is the [wgcf-mesh] branch, tag or commit
to download `wgcf-mesh.sh` from.

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
printf 'WGCF_MESH_TOKEN=%s\n' "$(cat token.txt)" |
  fly secrets import -a soju-ndq0bn8tgjuyd --stage

# 3. Build and deploy a single machine
fly deploy --ha=false
```

`--stage` stores the secrets without restarting anything; the first deploy
picks them up. `fly secrets import` reads the token from standard input,
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

From a device on your Mesh, open `http://100.96.x.x:8080` (the node's Mesh
IP, see [Cloudflare Mesh](#cloudflare-mesh)). gamja loads. Log in with
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

`sojuctl` and `sojudb` already know where the config is (`/etc/soju/config`).

## Cloudflare Mesh

With `WGCF_MESH_TOKEN` set, the first start runs [wgcf-mesh] to register a
Mesh node and saves its WireGuard config and device profile in
`/data/wgcf-mesh`. Every start after that reuses the saved config, so the
node keeps its device and Mesh IP across restarts and redeploys, and the
token isn't used again.

On every start, the entrypoint copies the saved config to
`/etc/wireguard/wg0.conf` and runs `wg-quick up wg0`, using the kernel's
WireGuard (Fly machines support it). The copy differs from the saved config:

- The `DNS` line is removed, so Fly's resolver stays in place.
- `AllowedIPs` is `WGCF_MESH_ROUTES` (`100.96.0.0/12`, the Mesh IPv4 range)
  instead of `::/0, 0.0.0.0/0`. With a default route through the tunnel,
  soju's upstream IRC connections and Fly's private network (`fly ssh`,
  logs) would go into it too.
- `MTU` is capped at the default route's MTU minus 80. The generated 1420
  assumes a 1500-byte link, but Fly's `eth0` is 1420 itself, so the tunnel
  gets 1340. With 1420, full-size packets are dropped: pings and requests
  work, but responses stall and gamja's WebSockets close ("socket is
  closed"). On a 1500-byte link the generated MTU is kept.
- `PostUp = ping -c2 -W2 100.96.0.7 || true` sends traffic through the
  tunnel right away, so it handshakes with Cloudflare at startup.

If the Mesh can't be brought up (a bad token, a failed registration), the
machine fails to start and Fly restarts it.

Set it up in the Cloudflare dashboard:

1. **Zero Trust → Networks → Mesh** (or [this link][create node]) → create a
   Mesh node and copy its token, which starts with `eyJhIjoi`.
2. Store it as a secret (see [Deploy](#deploy)) and deploy. The logs show
   wg-quick's commands, including the Mesh IP
   (`ip -4 address add 100.96.x.x/32 dev wg0`), and the node shows up in the
   dashboard as `soju-ndq0bn8tgjuyd`. `fly ssh console -C 'wg show'` shows
   the latest handshake.
3. On a device in the same Mesh (WARP client or another Mesh node), point the
   IRC client at `100.96.x.x:6667`, plain text, no TLS, with your soju
   username and password. gamja is also at `http://100.96.x.x:8080`.

To re-register (e.g. with a token for another node), delete the old device,
then remove the saved files and restart:

```sh
fly ssh console -C 'sh -c "cd /data/wgcf-mesh && wgcf-mesh.sh --delete wgcf-mesh-*.json && rm -f wgcf-mesh-*"'
printf 'WGCF_MESH_TOKEN=%s\n' "$(cat new-token.txt)" | fly secrets import  # restarts the machine
```

Without `WGCF_MESH_TOKEN` and without a saved config, the Mesh is skipped.
gamja and IRC are then only reachable from Fly's private network, e.g.
`fly proxy 8080` then `http://localhost:8080`.

Per wgcf-mesh, a WireGuard node can't serve IPv6 CIDR routes, hostname
routes or high availability. Plain IPv4 Mesh IPs, which this setup uses,
work.

## Updating

- `fly deploy` rebuilds the image and picks up the latest soju from Alpine
  edge and the latest `wgcf-mesh.sh`. The DB and the Mesh registration live
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
To copy the DB out:

```sh
fly ssh sftp get /data/soju/main.db main.db
```

## Run locally

```sh
docker build -t soju-fly soju-fly/
docker run --rm -p 8080:8080 -v soju-data:/data \
  --cap-add NET_ADMIN \
  -e SOJU_ADMIN_USER=admin -e SOJU_ADMIN_PASSWORD=changeme \
  -e WGCF_MESH_TOKEN=eyJhIjoi... \
  soju-fly
```

`--cap-add NET_ADMIN` is only needed with `WGCF_MESH_TOKEN`, and the host
kernel must have WireGuard. On Fly, the machine is a full VM with its own
kernel, which has it.

## Notes

- nginx sees Mesh clients' own Mesh IPs and forwards them to soju as a
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
- gamja is served over plain HTTP. The Mesh tunnel encrypts the traffic in
  transit.

[Fly.io]: https://fly.io/
[soju]: https://soju.im/
[gamja]: https://codeberg.org/emersion/gamja
[pbtrung/gamja]: https://github.com/pbtrung/gamja
[wgcf-mesh]: https://github.com/AnimMouse/wgcf-mesh
[Cloudflare Mesh]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/
[create node]: https://dash.cloudflare.com/?to=/:account/mesh
[config file]: https://codeberg.org/emersion/gamja/src/branch/master/doc/config-file.md
