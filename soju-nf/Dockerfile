ARG TWINGATE_REF=latest
FROM twingate/connector:${TWINGATE_REF} AS twingate

FROM alpine:edge AS builder

# Fail a RUN when any command of a pipe fails, not just the last one
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG GAMJA_REF=latest
ARG SOJU_REF=latest
ARG TARGETARCH=amd64

RUN apk --no-cache upgrade && \
    apk --no-cache add jq

# soju: static musl build from a pbtrung/soju-rs release (the latest one by
# default), checked against the release's SHA256SUMS. The release metadata
# is fetched with ADD, which downloads it on every build: when it changes
# (a new release), the cached layers below are rebuilt. Fetching it in RUN
# would reuse the first build's "latest" forever.
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
    /out/soju/soju -version

# gamja: prebuilt release from pbtrung/gamja, seeded into /data/gamja on
# first start
ADD https://api.github.com/repos/pbtrung/gamja/releases/latest /tmp/gamja-latest.json
COPY update-gamja.sh /usr/local/bin/
RUN tag="${GAMJA_REF}" && \
    if [ "$tag" = latest ]; then tag="$(jq -er .tag_name /tmp/gamja-latest.json)"; fi && \
    GAMJA_DATA_DIR=/out/gamja update-gamja.sh "$tag"

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

# soju keeps uid/gid 1000: an existing /data/soju stays owned by the same
# user
RUN addgroup -g 1000 soju && \
    adduser -u 1000 -G soju -D soju && \
    addgroup -S twingate && \
    adduser -S -G twingate -H -h /run/twingate twingate

# rclone: copy DB backups off the container (backup-soju.sh, daily by crond).
# sqlite: inspect databases and take consistent backups from a shell.
RUN apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata mailcap nginx su-exec \
      rclone sqlite

COPY --from=builder /out/gamja /usr/share/gamja-dist
# soju-rs binaries have no built-in config path: the soju and sojuctl
# wrappers in /usr/local/bin pass -config /etc/soju/config, so sojuctl works
# without flags inside the container shell.
COPY --from=builder /out/soju /usr/local/lib/soju
COPY soju-wrapper.sh /usr/local/bin/soju
COPY soju-wrapper.sh /usr/local/bin/sojuctl
COPY soju.conf /usr/share/soju/config
COPY --from=builder /out/twingate /opt/twingate
RUN ln -s /opt/twingate/connectorctl /usr/local/bin/connectorctl
# Where the connector keeps its API socket and crash reports; connectorctl
# (e.g. `connectorctl health` from a shell) finds the socket here
ENV TWINGATE_API_ENDPOINT=/run/twingate/connector.sock \
    TWINGATE_CRASH_REPORTING_DIR=/run/twingate/sentry
# The connector resolves Resources with glibc, which (unlike musl) reads
# nsswitch.conf: check /etc/hosts first, for TWINGATE_RESOURCE_HOST
# (entrypoint.sh)
RUN printf "hosts: files dns\n" >/etc/nsswitch.conf

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf
COPY update-gamja.sh /usr/local/bin/update-gamja.sh
COPY backup-soju.sh /usr/local/bin/backup-soju.sh

# 8080: nginx (gamja + WebSocket), 6667: soju plain IRC. Keep both private
# on Northflank: they're reached through the Twingate connector.
EXPOSE 8080 6667/tcp

ENTRYPOINT ["/script/entrypoint.sh"]
