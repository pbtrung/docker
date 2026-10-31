ARG TWINGATE_REF=latest
FROM twingate/connector:${TWINGATE_REF} AS twingate

FROM alpine:edge AS builder
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Twingate connector: the official image's binaries are linked against glibc,
# which Alpine doesn't have. Copy them with the glibc libraries they need
# (from the same image) into /out/twingate, and point their ELF interpreter
# and RPATH there. DT_RPATH (--force-rpath) rather than RUNPATH, because it
# also applies to the libraries' own dependencies (libsystemd's libzstd,
# liblz4, ...), so none of Alpine's musl libraries get loaded.
COPY --from=twingate /connectord /connectorctl /tmp/twingate/bin/
COPY --from=twingate /lib/ /tmp/twingate/lib/
COPY --from=twingate /usr/lib/ /tmp/twingate/usr-lib/
RUN apk --no-cache add patchelf && \
    mkdir -p /out/twingate/lib && \
    cp -a /tmp/twingate/lib/*-linux-gnu*/* /tmp/twingate/usr-lib/*-linux-gnu*/* \
      /out/twingate/lib/ && \
    rm -rf /out/twingate/lib/gconv && \
    ld="$(basename /out/twingate/lib/ld-linux-*.so.*)" && \
    for bin in connectord connectorctl; do \
      cp /tmp/twingate/bin/$bin /out/twingate/ && \
      patchelf --set-interpreter "/opt/twingate/lib/$ld" \
        --force-rpath --set-rpath /opt/twingate/lib /out/twingate/$bin; \
    done

FROM alpine:edge

RUN apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata su-exec busybox-extras \
      weechat weechat-lua tmux rclone tini && \
    addgroup -g 1000 soju && \
    adduser -u 1000 -G soju -D -H -h /data -s /bin/ash soju && \
    addgroup -S twingate && \
    adduser -S -G twingate -H -h /run/twingate twingate

COPY --from=builder /out/twingate /opt/twingate
RUN ln -s /opt/twingate/connectorctl /usr/local/bin/connectorctl && \
    printf 'hosts: files dns\n' >/etc/nsswitch.conf
ENV TWINGATE_API_ENDPOINT=/run/twingate/connector.sock \
    TWINGATE_CRASH_REPORTING_DIR=/run/twingate/sentry

RUN printf 'soju\n' >/etc/hostname

COPY healthz /usr/share/health/healthz
COPY inetd.conf /etc/inetd.conf
COPY .tmux.conf /usr/share/soju/.tmux.conf
COPY entrypoint.sh /script/entrypoint.sh
WORKDIR /data

# Keep both ports private; 8080 serves the platform HTTP health check.
EXPOSE 23/tcp 8080/tcp
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
ENTRYPOINT ["/sbin/tini", "-g", "--", "/script/entrypoint.sh"]
