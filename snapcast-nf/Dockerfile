FROM alpine:edge AS builder

ARG RQBIT_REF=latest
ARG SNAPCAST_RS_REF=latest
ARG SNAPWEB_REF=latest

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add wget curl unzip coreutils

# rqbit: official static release binary
RUN mkdir -p /out && \
    if [ "$RQBIT_REF" = latest ]; then \
      url=https://github.com/ikatson/rqbit/releases/latest/download/rqbit-linux-amd64; \
    else \
      url="https://github.com/ikatson/rqbit/releases/download/${RQBIT_REF}/rqbit-linux-amd64"; \
    fi && \
    wget -q -O /out/rqbit "$url" && \
    chmod +x /out/rqbit && \
    /out/rqbit --version

# snapserver-rs: static (musl) release binary from pbtrung/snapcast-rs,
# checked against the release's SHA256SUMS
WORKDIR /out
RUN if [ "$SNAPCAST_RS_REF" = latest ]; then \
      base=https://github.com/pbtrung/snapcast-rs/releases/latest/download; \
    else \
      base="https://github.com/pbtrung/snapcast-rs/releases/download/${SNAPCAST_RS_REF}"; \
    fi && \
    wget -q "$base/snapserver-rs-x86_64-unknown-linux-musl" "$base/SHA256SUMS" && \
    sha256sum --ignore-missing -c SHA256SUMS && \
    mv snapserver-rs-x86_64-unknown-linux-musl snapserver-rs && \
    rm SHA256SUMS && \
    chmod +x snapserver-rs && \
    ./snapserver-rs --version

# snapweb: prebuilt release from pbtrung/snapweb, seeded into /data/snapweb
# on first start
COPY update-snapweb.sh /usr/local/bin/
RUN SNAPWEB_DATA_DIR=/out/snapweb update-snapweb.sh "${SNAPWEB_REF}"

FROM alpine:edge

RUN addgroup -g 1000 snapcast && \
    adduser -u 1000 -G snapcast -D snapcast

# play.sh needs bash, GNU coreutils (timeout --foreground, numfmt, sort -V),
# gawk, jq, curl, ffmpeg/ffprobe, and procps-ng (pkill -g). nginx serves
# Snapweb; unzip is for update-snapweb.sh.
# cloudflared comes from the edge testing repository.
RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata bash coreutils findutils gawk \
        sed grep jq curl ffmpeg procps-ng su-exec nginx unzip && \
    apk --no-cache add \
        --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing \
        cloudflared

COPY --from=builder /out/rqbit /out/snapserver-rs /usr/local/bin/
COPY --from=builder /out/snapweb /usr/share/snapweb-dist

WORKDIR /script
COPY entrypoint.sh play.sh /script/
COPY nginx.conf /script/nginx.conf
COPY snapserver.conf /etc/snapserver.conf
COPY update-snapweb.sh /usr/local/bin/update-snapweb.sh

# 8080: nginx (Snapweb + /jsonrpc and /stream WebSockets), public HTTP port
#       on Northflank
# 1704: snapclient audio stream, private TCP port
# 1705: JSON-RPC over TCP, private TCP port
# snapserver's own HTTP port 1780 is only used through nginx
EXPOSE 8080 1704/tcp 1705/tcp

ENTRYPOINT ["/script/entrypoint.sh"]
