FROM alpine:edge AS builder
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG GAMJA_REF=latest
ARG SOJU_REF=latest
ARG TARGETARCH

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

ARG CLOUDFLARED_REF=latest
RUN case "${TARGETARCH}" in \
      amd64|arm64) ;; \
      *) printf 'Unsupported cloudflared architecture: %s\n' "${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    if [ "${CLOUDFLARED_REF}" = latest ]; then \
      release_url=https://github.com/cloudflare/cloudflared/releases/latest/download; \
    else \
      release_url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_REF}"; \
    fi && \
    wget -q -O /out/cloudflared "${release_url}/cloudflared-linux-${TARGETARCH}" && \
    chmod 755 /out/cloudflared

FROM alpine:edge

RUN apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata su-exec busybox-extras \
      sqlite rclone tini lighttpd mailcap tinyssh && \
    addgroup -g 1000 soju && \
    adduser -u 1000 -G soju -D -H -h /data -s /bin/ash soju && \
    addgroup -S cloudflared && \
    adduser -S -G cloudflared -H -h /nonexistent cloudflared

RUN printf 'soju\n' >/etc/hostname

COPY --from=builder /out/soju /usr/local/lib/soju
COPY soju-wrapper.sh /usr/local/bin/soju
COPY soju-wrapper.sh /usr/local/bin/sojuctl
COPY soju.conf /usr/share/soju/config
COPY backup-soju.sh update-gamja.sh /usr/local/bin/
COPY --from=builder /out/cloudflared /usr/local/bin/cloudflared
COPY --from=builder /out/gamja /usr/share/gamja-dist
COPY lighttpd.conf /script/lighttpd.conf
COPY setup-ssh.sh /usr/local/bin/setup-ssh.sh
COPY start-tinyssh.sh /usr/local/bin/start-tinyssh.sh
COPY inetd.conf /etc/inetd.conf
COPY term.sh /etc/profile.d/term.sh
COPY entrypoint.sh /script/entrypoint.sh
WORKDIR /data
RUN mkdir -p /var/www/localhost/htdocs && printf 'ok\n' >/var/www/localhost/htdocs/healthz
RUN touch /tmp/lighttpd-error.log /tmp/lighttpd-access.log && \
    chown soju:soju /tmp/lighttpd-error.log /tmp/lighttpd-access.log

# SSH listens only on loopback; keep gamja/HTTP health check private.
EXPOSE 8080/tcp 6667/tcp
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
ENTRYPOINT ["/sbin/tini", "-s", "-g", "--", "/script/entrypoint.sh"]
