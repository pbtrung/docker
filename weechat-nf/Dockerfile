FROM twingate/connector:1 AS twingate

FROM alpine:edge AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG GLOWING_BEAR_REF=latest

RUN apk update && \
    apk --no-cache upgrade

# Glowing Bear: prebuilt release from pbtrung/glowing-bear, seeded into
# /data/glowing-bear on first start
COPY update-glowing-bear.sh /usr/local/bin/
RUN GLOWING_BEAR_DIR=/out/glowing-bear \
      update-glowing-bear.sh "${GLOWING_BEAR_REF}"

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
    apk --no-cache add ca-certificates tzdata mailcap nginx su-exec \
      weechat weechat-lua

RUN addgroup -g 1000 weechat && \
    adduser -u 1000 -G weechat -D weechat && \
    addgroup -S twingate && \
    adduser -S -G twingate -H -h /run/twingate twingate

COPY --from=builder /out/glowing-bear /usr/share/glowing-bear-dist
COPY --from=builder /out/twingate /opt/twingate
RUN ln -s /opt/twingate/connectorctl /usr/local/bin/connectorctl && \
    printf "hosts: files dns\n" >/etc/nsswitch.conf
ENV TWINGATE_API_ENDPOINT=/run/twingate/connector.sock \
    TWINGATE_CRASH_REPORTING_DIR=/run/twingate/sentry

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf
COPY weechat-cmd /usr/local/bin/weechat-cmd
COPY update-glowing-bear.sh /usr/local/bin/update-glowing-bear.sh

# 8080: nginx (Glowing Bear + relay WebSocket), private on Northflank,
# reached through the Twingate connector.
# The WeeChat relay itself listens on 127.0.0.1:9001 only.
EXPOSE 8080

ENTRYPOINT ["/script/entrypoint.sh"]
