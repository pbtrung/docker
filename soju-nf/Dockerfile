FROM alpine:edge AS builder

ARG GAMJA_REF=latest

RUN apk update && \
    apk --no-cache upgrade

# cloudflared: official static release binary (no Alpine package)
RUN mkdir -p /out && \
    wget -q -O /out/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /out/cloudflared

# gamja: prebuilt release from pbtrung/gamja, seeded into /data/gamja on
# first start
COPY update-gamja.sh /usr/local/bin/
RUN GAMJA_DIR=/out/gamja update-gamja.sh "${GAMJA_REF}"

FROM alpine:edge

# Create the soju user (uid 1000) before installing the package, so the
# package's install script reuses it instead of adding a system user.
RUN addgroup -g 1000 soju && \
    adduser -u 1000 -G soju -D soju

# soju from the Alpine package: its sojuctl/sojudb default to
# /etc/soju/config and the admin socket /run/soju/admin, so they work
# without flags inside the container shell
RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata mailcap nginx su-exec soju

COPY --from=builder /out/cloudflared /usr/local/bin/
COPY --from=builder /out/gamja /usr/share/gamja-dist

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf
COPY update-gamja.sh /usr/local/bin/update-gamja.sh

# 8080: nginx (gamja + WebSocket), public HTTP port on Northflank
# 6667: soju plain IRC, private TCP port (Northflank can't expose TCP publicly)
EXPOSE 8080 6667/tcp

ENTRYPOINT ["/script/entrypoint.sh"]
