# snapserver-rs + Snapweb + torrent player on Northflank

A single container image that runs:

- [snapserver-rs] — Snapcast server from [pbtrung/snapcast-rs] (static musl
  release binary), started with `--config /etc/snapserver.conf`
- [Snapweb] — Snapcast web client, prebuilt release from the
  [pbtrung/snapweb] fork. It is kept on the volume so you can update it from
  a shell.
- nginx — serves Snapweb and proxies its WebSockets to snapserver-rs
- `play.sh` — downloads the lossless audio of each torrent in a list with
  [rqbit] (official static release binary), and plays it into snapserver's
  FIFO
- cloudflared (optional) — Cloudflare Tunnel, from the Alpine edge
  `testing` repository

```
browser ──https──▶ Northflank LB ──▶ :8080 nginx ─┬─ /          Snapweb static files (/data/snapweb)
                   (TLS terminated)               ├─ /jsonrpc   ─▶ snapserver-rs 127.0.0.1:1780 (WebSocket / POST)
                                                  ├─ /stream    ─▶ snapserver-rs 127.0.0.1:1780 (WebSocket audio)
                                                  └─ /healthz   200 ok
                                    :1704 snapclient audio stream (private TCP)
                                    :1705 JSON-RPC over TCP     (private TCP)

play.sh ── rqbit download ──▶ /data/snapcast/download/<batch>/
        └─ ffmpeg (soxr 48 kHz, dynaudnorm, f32le) ──▶ /tmp/snapfifo ──▶ snapserver-rs (Opus 256 kbit/s)
```

Northflank only exposes HTTP ports publicly. So Snapweb (port 8080) is
public, while native `snapclient`s need the private TCP port 1704. Reach it
through a Cloudflare Tunnel (see [Cloudflare Tunnel](#cloudflare-tunnel)), or
from another service in the same Northflank project.

`/data` should be a Northflank volume. It holds:

```
/data/
├── magnet.txt          torrent list played by play.sh (PLAY_LIST), you create it
├── snapcast/           play.sh working dir: download/ batches, rqbit.log
├── snapweb/            Snapweb (SNAPWEB_DATA_DIR), snapserver's doc_root
└── update-snapweb.sh   Snapweb updater, copied on every start
```

## Files

| File                | Purpose |
| ------------------- | ------- |
| `Dockerfile`        | `builder` stage downloads rqbit, snapserver-rs (checked against `SHA256SUMS`) and a Snapweb release; runtime stage on alpine:edge installs bash, ffmpeg, nginx, … and cloudflared from edge/testing |
| `entrypoint.sh`     | Installs Snapweb on the volume, creates the FIFO, starts cloudflared, `play.sh`, nginx, then snapserver-rs |
| `play.sh`           | Downloads torrents in batches with rqbit and plays them into `/tmp/snapfifo` |
| `snapserver.conf`   | snapserver-rs config: `pipe:///tmp/snapfifo?…&encoding=float` source, Opus codec, `doc_root = /data/snapweb/` |
| `nginx.conf`        | Serves Snapweb, proxies `/jsonrpc` and `/stream`, `/healthz`, rate limits |
| `update-snapweb.sh` | Installs a Snapweb release (latest, or a given tag) into `SNAPWEB_DATA_DIR` |

## How play.sh works

Each non-empty line of the list (`#` starts a comment) is a magnet link, a
torrent URL or a `.torrent` path. For each torrent, `play.sh`:

1. lists its files with `rqbit download --list` and keeps the audio ones
   (`flac wav ape wv tta aiff aif alac m4a mka`). `.m4a` / `.mka` files are
   kept only if their codec is lossless.
2. splits them into batches of at most 10 GiB (`BATCH_MAX`). It keeps each
   album directory together when it fits.
3. downloads one batch at a time into `/data/snapcast/download/<seq>`, at
   most one batch ahead of the one playing. Uploads are limited to 256 KB/s.
4. plays each batch `ROUNDS` (2) times, then deletes it.

Each track is decoded by ffmpeg, which reads it at 1.05× real time after a
10 s burst (`-readrate 1.05 -readrate_initial_burst 10`). The audio is
resampled to 48 kHz with soxr, normalized with `dynaudnorm`, and written to
`/tmp/snapfifo` as 32-bit float PCM. Track tags are sent to snapserver
(`Stream.SetProperty`), so Snapweb shows what is playing.

Batches that finished downloading before a restart are played once on the
next start. Unfinished ones are deleted.

`play.sh` runs once per container start. When the list is done, snapserver
keeps running (silent). To play a new list, edit `/data/magnet.txt` and
restart the service.

## Environment variables

| Variable            | Default                | Description |
| ------------------- | ---------------------- | ----------- |
| `CLOUDFLARED_TOKEN` | —                      | Cloudflare Tunnel token. If set, runs `cloudflared tunnel run` |
| `PLAY_LIST`         | `/data/magnet.txt`     | Torrent list for `play.sh`. If the file doesn't exist, nothing is played |
| `SNAPSERVER_CONF`   | `/etc/snapserver.conf` | snapserver-rs config (the bundled `snapserver.conf`). Point it at a file on the volume to use your own |
| `SNAPCAST_DATA_DIR` | `/data/snapcast`       | `play.sh` working directory (downloads, `rqbit.log`) |
| `SNAPWEB_DATA_DIR`  | `/data/snapweb`        | Where Snapweb is installed. If you change it, change `doc_root` in the snapserver config too |
| `NGINX_CONF`        | `/script/nginx.conf`   | nginx config |

Build arguments (all default to `latest`):

| Argument          | Selects |
| ----------------- | ------- |
| `RQBIT_REF`       | rqbit release tag, e.g. `v9.0.1` |
| `SNAPCAST_RS_REF` | snapcast-rs release tag, e.g. `v0.999.15` |
| `SNAPWEB_REF`     | Snapweb release tag bundled in the image. It's only installed on a volume that doesn't have Snapweb yet |

## Deploy on Northflank (web UI)

### 1. Push this repo to a Git provider

Push this repository to GitHub, GitLab or Bitbucket. In Northflank, connect
that provider under **Account / Team settings → Git integrations**, and give
Northflank access to the repository.

### 2. Create a project

**Create new → Project**. Pick a name (e.g. `music`) and a region close to you.

### 3. Create a combined service

Inside the project: **Create new → Service → Combined service**.

- **Name:** `snapcast`
- **Repository:** this repo, branch `main`
- **Build type:** `Dockerfile`
  - **Dockerfile location:** `/snapcast-nf/Dockerfile`
  - **Build context:** `/snapcast-nf`
  - (optional) **Build arguments:** `RQBIT_REF`, `SNAPCAST_RS_REF`,
    `SNAPWEB_REF` to pin releases
- **Resources:** ffmpeg (soxr + dynaudnorm) and the Opus encoder need about
  half a vCPU; 1 GB of memory is plenty. **Instances: 1.**

### 4. Networking

Northflank reads `EXPOSE` from the Dockerfile. Check the **Ports** section:

| Port | Protocol | Public |
| ---- | -------- | ------ |
| 8080 | HTTP     | **Yes**. Gives you a `*.code.run` URL with TLS |
| 1704 | TCP      | No (snapclient audio, private) |
| 1705 | TCP      | No (JSON-RPC over TCP, private) |

If 8080 wasn't detected, add it by hand as **HTTP** and turn on **Publicly
expose this port to the internet**.

### 5. Environment variables

Under **Environment variables** (runtime), add the Cloudflare Tunnel token
as a **secret**:

```
CLOUDFLARED_TOKEN=<token from the Cloudflare dashboard>
```

The other variables have working defaults.

### 6. Add a persistent volume

Open the service → **Volumes → Add volume**:

- **Name:** `snapcast-data`
- **Size:** at least 2 × `BATCH_MAX` plus some headroom. Two 10 GiB batches
  can be on disk at once, so **25 GB**. Lower `BATCH_MAX` in `play.sh` if you
  want a smaller volume.
- **Mount path:** `/data`

### 7. Health check (recommended)

Service → **Health checks → Add health check**:

- **Protocol:** HTTP, **Port:** 8080, **Path:** `/healthz`

### 8. Add the torrent list

Open a shell on the running container (service → **Containers** → **Shell**)
and write the list:

```sh
cat > /data/magnet.txt <<'EOF'
# one magnet link / torrent URL per line
magnet:?xt=urn:btih:...
https://example.org/album.torrent
EOF
```

Restart the service (**Restart** in the service header). `play.sh` starts and
its output appears in the container logs (`>>> Listing`, `>>> Downloading
batch`, `Playing: …`). rqbit's own log is in `/data/snapcast/rqbit.log`.

### 9. Listen

Open the public URL. Snapweb loads and connects to the server on the same
host (`wss://<host>/jsonrpc`). Use its play button to listen in the browser
(`wss://<host>/stream`). If Snapweb asks for the server, enter
`wss://<host>`.

For a native `snapclient`, use the Cloudflare Tunnel TCP route below.

### Updating

- Pushing to `main` triggers a rebuild and redeploy. To pick up new rqbit,
  snapcast-rs or Alpine packages without changing this repo, start a build
  by hand from the service's **Builds** tab.
- Snapweb is updated from a shell instead (see
  [Updating Snapweb](#updating-snapweb)). A new image doesn't replace the copy
  on the volume.

## Cloudflare Tunnel

If `CLOUDFLARED_TOKEN` is set, the entrypoint runs
`cloudflared tunnel --no-autoupdate run --token $CLOUDFLARED_TOKEN` in the
background, as the `snapcast` user. cloudflared only makes outbound
connections, so it needs no inbound port on Northflank. If cloudflared exits
(bad token, crash), the container stops and Northflank restarts it.

Set it up in the Cloudflare Zero Trust dashboard:

1. **Networks → Tunnels → Create a tunnel**, type **Cloudflared**, name it
   (e.g. `snapcast`).
2. Copy the token from the install command (the string after `--token`).
   Set it as the secret `CLOUDFLARED_TOKEN` in Northflank and save. The
   service restarts and the tunnel shows as **Healthy**.
3. Add **public hostname** routes, for example:
   - `snap.example.org` → `http://localhost:8080` to serve Snapweb on your
     own domain.
   - `snapstream.example.org` → `tcp://localhost:1704` for native
     snapclients. On each client machine, run
     `cloudflared access tcp --hostname snapstream.example.org --url localhost:1704`,
     then `snapclient tcp://localhost:1704`.

The routes are stored in Cloudflare (a remotely managed tunnel), so changing
them needs no redeploy.

## Updating Snapweb

Snapweb is served from `/data/snapweb`. On the first start, the entrypoint
copies the release bundled in the image there. On every start, it copies
`update-snapweb.sh` to `/data`. To switch to another release of
[pbtrung/snapweb] without a new image, run in a container shell:

```sh
/data/update-snapweb.sh           # latest release
/data/update-snapweb.sh v0.99.14  # a specific release tag
FORCE=1 /data/update-snapweb.sh   # reinstall even if already installed
```

It unpacks the release `.zip` next to the current copy and swaps the two
directories, so nginx never serves a half-installed tree. The installed tag
is in `/data/snapweb/.version`. Reload Snapweb in the browser afterwards. No
restart is needed.

## Run locally

```sh
docker build -t snapcast snapcast-nf/
docker run --rm -p 8080:8080 -p 1704:1704 -v snapcast-data:/data snapcast
```

Open http://localhost:8080, or run `snapclient tcp://localhost:1704`. To
play something, put a list in the volume (e.g. `docker cp magnet.txt
<container>:/data/magnet.txt`) and restart the container.

## Notes

- snapserver-rs's control API has no authentication (`--auth` is off). Anyone
  who can open the public URL can control the server. Restrict access with
  Cloudflare Access on the tunnel hostname if that matters.
- `play.sh` traps Ctrl-C / TERM and does `kill 0` on its process group, so
  the entrypoint starts it with `setsid`. Otherwise the trap would also kill
  snapserver-rs.
- The entrypoint creates `/tmp/snapfifo` before snapserver-rs and `play.sh`
  start, so they don't race to create it.
- snapserver-rs starts first. `play.sh` waits until it answers JSON-RPC on
  `127.0.0.1:1780`, so the first track's metadata reaches it.
- snapserver-rs is the main process (the entrypoint execs it): if it exits,
  the container stops and Northflank restarts it. Finished batches are then
  played once (see above). The entrypoint finds it by its own PID, not PID 1,
  since the platform may run its own init as PID 1.
- cloudflared follows the Alpine edge `testing` package, so each rebuild picks
  up whatever version it ships.

[snapserver-rs]: https://github.com/pbtrung/snapcast-rs
[pbtrung/snapcast-rs]: https://github.com/pbtrung/snapcast-rs
[Snapweb]: https://github.com/badaix/snapweb
[pbtrung/snapweb]: https://github.com/pbtrung/snapweb
[rqbit]: https://github.com/ikatson/rqbit
