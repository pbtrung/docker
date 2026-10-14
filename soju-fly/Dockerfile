FROM alpine:edge AS builder

ARG GAMJA_REF=latest
ARG WGCF_MESH_REF=main
ARG DNCLIENT_VERSION=latest
ARG TARGETARCH=amd64

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add jq

# wgcf-mesh: registers a Cloudflare Mesh node and writes its WireGuard config
RUN mkdir -p /out && \
    wget -q -O /out/wgcf-mesh.sh \
      "https://raw.githubusercontent.com/AnimMouse/wgcf-mesh/${WGCF_MESH_REF}/wgcf-mesh.sh" && \
    chmod +x /out/wgcf-mesh.sh

# dnclient: static binary from Defined Networking's downloads
# (https://www.defined.net/downloads/). The API lists each version's URLs,
# plus "latest".
RUN wget -q -O /tmp/dn-downloads.json https://api.defined.net/v1/downloads && \
    url="$(jq -er --arg v "${DNCLIENT_VERSION}" --arg p "linux-${TARGETARCH}" \
      '.data.dnclient[$v][$p]' /tmp/dn-downloads.json)" && \
    echo "Downloading $url" && \
    wget -q -O /out/dnclient "$url" && \
    chmod +x /out/dnclient && \
    /out/dnclient -version

# gamja: prebuilt release from pbtrung/gamja, seeded into /data/gamja on
# first start
COPY update-gamja.sh /usr/local/bin/
RUN GAMJA_DATA_DIR=/out/gamja update-gamja.sh "${GAMJA_REF}"

FROM alpine:edge

# Create the soju user (uid 1000) before installing the package, so the
# package's install script reuses it instead of adding a system user.
RUN addgroup -g 1000 soju && \
    adduser -u 1000 -G soju -D soju

# soju from the Alpine package: its sojuctl/sojudb default to
# /etc/soju/config and the admin socket /run/soju/admin, so they work
# without flags inside the container shell.
# bash, curl, jq: wgcf-mesh.sh. wireguard-tools: wg-quick brings up the
# Mesh interface with the kernel's WireGuard. rclone: copy backups off the
# machine from a shell.
RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata mailcap nginx su-exec soju \
      bash curl jq iproute2 wireguard-tools rclone

COPY --from=builder /out/wgcf-mesh.sh /usr/local/bin/
COPY --from=builder /out/gamja /usr/share/gamja-dist
COPY --from=builder /out/dnclient /usr/local/bin/dnclient

# dnclient keeps its enrollment on the volume instead of /var/lib/defined,
# so restarts and redeploys don't enroll the host again. Set in the image
# so `dnclient info` in a shell finds the same state and socket.
ENV DNCLIENT_STATE_DIR=/data/defined \
    DNCLIENT_SOCKET_DIR=/run

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf
COPY update-gamja.sh /usr/local/bin/update-gamja.sh

# 8080: nginx (gamja + WebSocket), 6667: soju plain IRC. fly.toml exposes
# neither publicly: both are only reachable over Cloudflare Mesh, the
# Defined Networking (Nebula) overlay and Fly's private network.
EXPOSE 8080 6667/tcp

ENTRYPOINT ["/script/entrypoint.sh"]
