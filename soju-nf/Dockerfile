FROM alpine:edge AS builder

ARG GAMJA_REF=master

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add git nodejs npm

RUN git clone --depth 1 --branch "${GAMJA_REF}" https://github.com/pbtrung/gamja.git /src/gamja

# cloudflared: official static release binary (no Alpine package)
RUN mkdir -p /out && \
    wget -q -O /out/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /out/cloudflared

# gamja: static web client
WORKDIR /src/gamja
RUN npm install --include=dev && \
    npm run build

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
COPY --from=builder /src/gamja/dist /usr/share/gamja

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf

# 8080: nginx (gamja + WebSocket), public HTTP port on Northflank
# 6667: soju plain IRC, private TCP port (Northflank can't expose TCP publicly)
EXPOSE 8080 6667/tcp

ENTRYPOINT ["/script/entrypoint.sh"]
