FROM alpine:edge AS builder

# Fail a RUN when any command of a pipe fails, not just the last one
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG GAMJA_REF=latest
ARG SOJU_REF=latest
ARG TARGETARCH=amd64

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add jq

# Release metadata is fetched with ADD, which downloads it on every build:
# when it changes (e.g. a new release), the cached layers below are rebuilt.
# Fetching it in RUN would reuse the first build's "latest" forever, since
# RUN layers are cached by command, not by what the command downloads.

# soju: static musl build from a pbtrung/soju-rs release (the latest one by
# default), checked against the release's SHA256SUMS
ADD https://api.github.com/repos/pbtrung/soju-rs/releases/latest /tmp/soju-latest.json
WORKDIR /tmp/soju
RUN case "${TARGETARCH}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "Unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    if [ "${SOJU_REF}" = latest ]; then \
      tag="$(jq -er .tag_name /tmp/soju-latest.json)"; \
    else \
      tag="$(wget -q -O - "https://api.github.com/repos/pbtrung/soju-rs/releases/tags/${SOJU_REF}" | \
        jq -er .tag_name)"; \
    fi && \
    name="soju-rs-${tag}-${arch}-unknown-linux-musl" && \
    base="https://github.com/pbtrung/soju-rs/releases/download/${tag}" && \
    mkdir -p /out/soju && \
    echo "Downloading $base/$name.tar.gz" && \
    wget -q "$base/$name.tar.gz" "$base/SHA256SUMS" && \
    grep " $name.tar.gz\$" SHA256SUMS | sha256sum -c - && \
    tar -xzf "$name.tar.gz" && \
    cp "$name/soju" "$name/sojuctl" "$name/LICENSE" /out/soju/ && \
    printf "%s\n" "$tag" >/out/soju/.version && \
    { /out/soju/soju -help 2>&1 || true; } | grep -q "^Usage of soju"

# gamja: prebuilt release from pbtrung/gamja, seeded into /data/gamja on
# first start. The metadata only invalidates the cache: update-gamja.sh
# fetches it again.
ADD https://api.github.com/repos/pbtrung/gamja/releases/latest /tmp/gamja-latest.json
COPY update-gamja.sh /usr/local/bin/
RUN GAMJA_DATA_DIR=/out/gamja update-gamja.sh "${GAMJA_REF}"

# Cloudflare's IP ranges, the only sources HAProxy lets through to 8443
# (haproxy.cfg). Fetched with ADD on every build, like the releases above.
# The lists have no final newline; every line must be a CIDR range.
ADD https://www.cloudflare.com/ips-v4/ /tmp/cf-ips-v4.txt
ADD https://www.cloudflare.com/ips-v6/ /tmp/cf-ips-v6.txt
RUN mkdir -p /out/haproxy && \
    { cat /tmp/cf-ips-v4.txt; echo; cat /tmp/cf-ips-v6.txt; echo; } | \
      tr -d '\r' | sed 's/^ *//;s/ *$//;/^$/d' >/out/haproxy/cloudflare-ips.txt && \
    if grep -Evq '^([0-9.]+|[0-9a-f:]+)/[0-9]+$' /out/haproxy/cloudflare-ips.txt; then \
      echo "Unexpected line in Cloudflare's IP lists:" >&2; \
      grep -Ev '^([0-9.]+|[0-9a-f:]+)/[0-9]+$' /out/haproxy/cloudflare-ips.txt >&2; \
      exit 1; \
    fi && \
    grep -q '\.' /out/haproxy/cloudflare-ips.txt && \
    grep -q ':' /out/haproxy/cloudflare-ips.txt && \
    cat /out/haproxy/cloudflare-ips.txt

FROM alpine:edge

RUN addgroup -g 1000 soju && \
    adduser -u 1000 -G soju -D soju

# haproxy: HTTPS, Cloudflare IP filter, routing; busybox-extras: httpd for
# gamja's files.
# rclone: copy backups off the machine from a shell.
# sqlite: inspect the soju DB and take consistent backups from a shell.
RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata haproxy busybox-extras su-exec \
      rclone sqlite

COPY --from=builder /out/gamja /usr/share/gamja-dist
COPY --from=builder /out/haproxy/cloudflare-ips.txt /etc/haproxy/
# soju-rs binaries have no built-in config path: the soju and sojuctl
# wrappers in /usr/local/bin pass -config /etc/soju/config, so sojuctl works
# without flags inside the container shell.
COPY --from=builder /out/soju /usr/local/lib/soju
COPY soju-wrapper.sh /usr/local/bin/soju
COPY soju-wrapper.sh /usr/local/bin/sojuctl
COPY soju.conf /etc/soju/config

WORKDIR /script
COPY entrypoint.sh /script/
COPY haproxy.cfg httpd.conf /script/
COPY update-gamja.sh /usr/local/bin/update-gamja.sh

# 8080: HAProxy (gamja + WebSocket), 6667: soju plain IRC. Both are only
# reachable over Fly's private network.
# 8443: HAProxy, public on 443 through Cloudflare (see fly.toml).
EXPOSE 8080 8443 6667/tcp

ENTRYPOINT ["/script/entrypoint.sh"]
