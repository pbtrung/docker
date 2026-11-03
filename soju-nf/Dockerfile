FROM alpine:edge AS builder
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG GLOWING_BEAR_REF=latest
COPY update-glowing-bear.sh /usr/local/bin/
RUN GLOWING_BEAR_DIR=/out/glowing-bear \
    update-glowing-bear.sh "${GLOWING_BEAR_REF}"

ARG CLOUDFLARED_REF=latest
ARG TARGETARCH
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
      weechat weechat-lua mimalloc3 rclone tini lighttpd mailcap tinyssh && \
    addgroup -g 1000 soju && \
    adduser -u 1000 -G soju -D -H -h /data -s /bin/ash soju && \
    addgroup -S cloudflared && \
    adduser -S -G cloudflared -H -h /nonexistent cloudflared

RUN printf 'soju\n' >/etc/hostname

COPY backup-weechat.sh /usr/local/bin/backup-weechat.sh
COPY start-weechat.sh /usr/local/bin/start-weechat.sh
COPY --from=builder /out/cloudflared /usr/local/bin/cloudflared
COPY --from=builder /out/glowing-bear /usr/share/glowing-bear-dist
COPY lighttpd.conf /script/lighttpd.conf
COPY update-glowing-bear.sh weechat-cmd /usr/local/bin/
COPY setup-ssh.sh /usr/local/bin/setup-ssh.sh
COPY start-tinyssh.sh /usr/local/bin/start-tinyssh.sh
COPY inetd.conf /etc/inetd.conf
COPY term.sh /etc/profile.d/term.sh
COPY entrypoint.sh /script/entrypoint.sh
WORKDIR /data
RUN mkdir -p /var/www/localhost/htdocs && printf 'ok\\n' >/var/www/localhost/htdocs/healthz
RUN touch /tmp/lighttpd-error.log /tmp/lighttpd-access.log && \
    chown soju:soju /tmp/lighttpd-error.log /tmp/lighttpd-access.log

# SSH listens only on loopback; keep Glowing Bear/HTTP health check private.
EXPOSE 8080/tcp
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
ENTRYPOINT ["/sbin/tini", "-s", "-g", "--", "/script/entrypoint.sh"]
