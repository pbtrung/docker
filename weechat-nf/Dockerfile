FROM twingate/connector:1 AS twingate

FROM alpine:edge AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG TTYD_RS_REF=a10f6739e8b94e21ecc775bfa8dd4bb62e1f90ff

RUN apk update && \
    apk --no-cache upgrade

# The browser assets are checked into ttyd-rs and embedded by cargo.
RUN apk --no-cache add build-base cargo git rust
WORKDIR /src/ttyd-rs
COPY ttyd-rs-musl.patch /tmp/ttyd-rs-musl.patch
RUN git init . && \
    git remote add origin https://github.com/pbtrung/ttyd-rs.git && \
    git fetch --depth 1 origin "${TTYD_RS_REF}" && \
    git checkout --detach FETCH_HEAD && \
    git apply /tmp/ttyd-rs-musl.patch && \
    cargo build --release --locked && \
    mkdir -p /out/ttyd-rs && \
    cp target/release/ttyd-rs LICENSE /out/ttyd-rs/

# The connector needs glibc. Keep its libraries separate from Alpine's
# musl libraries, using the same interpreter/RPATH setup as soju-fly.
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

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata nginx su-exec tini libgcc \
      weechat weechat-lua mimalloc3 rclone tmux zsh grml-zsh-config \
      ncurses-terminfo

RUN addgroup -g 1000 weechat && \
    adduser -u 1000 -G weechat -D -H -h /data/home -s /bin/zsh weechat && \
    addgroup -S twingate && \
    adduser -S -G twingate -H -h /run/twingate twingate

COPY --from=builder /out/ttyd-rs/ttyd-rs /usr/local/bin/ttyd-rs
COPY --from=builder /out/ttyd-rs/LICENSE /usr/share/licenses/ttyd-rs/LICENSE
COPY --from=builder /out/twingate /opt/twingate
RUN ln -s /opt/twingate/connectorctl /usr/local/bin/connectorctl && \
    printf "hosts: files dns\n" >/etc/nsswitch.conf
ENV TWINGATE_API_ENDPOINT=/run/twingate/connector.sock \
    TWINGATE_CRASH_REPORTING_DIR=/run/twingate/sentry

WORKDIR /script
COPY entrypoint.sh /script/
COPY start-weechat.sh /script/
COPY nginx.conf /script/nginx.conf
COPY ttyd-rs.toml /script/ttyd-rs.toml
COPY tmux.conf /etc/tmux.conf
COPY weechat-cmd /usr/local/bin/weechat-cmd
COPY weechat-attach /usr/local/bin/weechat-attach
COPY backup-weechat.sh /usr/local/bin/backup-weechat.sh

# 8080: nginx -> ttyd-rs (127.0.0.1:7681), private on Northflank,
# reached through the Twingate connector.
EXPOSE 8080

# Northflank may wrap the entrypoint, so Tini must also reap when not PID 1.
ENTRYPOINT ["/sbin/tini", "-s", "--", "/script/entrypoint.sh"]
