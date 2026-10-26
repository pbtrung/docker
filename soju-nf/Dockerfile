FROM twingate/connector:1 AS twingate

FROM alpine:edge AS builder

ARG GAMJA_REF=latest

RUN apk update && \
    apk --no-cache upgrade

# gamja: prebuilt release from pbtrung/gamja, seeded into /data/gamja on
# first start
COPY update-gamja.sh /usr/local/bin/
RUN GAMJA_DATA_DIR=/out/gamja update-gamja.sh "${GAMJA_REF}"

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

RUN addgroup -S twingate && \
    adduser -S -G twingate -H -h /run/twingate twingate

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata mailcap nginx su-exec

COPY --from=builder /out/gamja /usr/share/gamja-dist
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

# 8080: nginx (gamja). Keep it private on Northflank: it's reached through
# the Twingate connector.
EXPOSE 8080

ENTRYPOINT ["/script/entrypoint.sh"]
