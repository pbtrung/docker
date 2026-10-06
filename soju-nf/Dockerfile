FROM alpine:edge AS builder

ARG SOJU_REF=master
ARG GAMJA_REF=master

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add build-base git go nodejs npm

RUN git clone --depth 1 --branch "${SOJU_REF}" https://codeberg.org/emersion/soju.git /src/soju && \
    git clone --depth 1 --branch "${GAMJA_REF}" https://codeberg.org/emersion/gamja.git /src/gamja

# cloudflared: official static release binary (no Alpine package)
RUN mkdir -p /out && \
    wget -q -O /out/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /out/cloudflared

# soju: static binaries with config/admin-socket paths baked in so that
# `sojuctl` / `sojudb` work without flags inside the container shell
WORKDIR /src/soju
RUN go build -o /out/ \
      -ldflags "-linkmode=external -extldflags=-static \
        -X codeberg.org/emersion/soju/config.DefaultPath=/etc/soju/config \
        -X codeberg.org/emersion/soju/config.DefaultUnixAdminPath=/run/soju/admin.sock" \
      ./cmd/soju ./cmd/sojudb ./cmd/sojuctl

# gamja: static web client
WORKDIR /src/gamja
RUN npm install --include=dev && \
    npm run build

FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata mailcap nginx su-exec

RUN addgroup -g 1000 soju && \
    adduser -u 1000 -G soju -D soju

COPY --from=builder /out/soju /out/sojudb /out/sojuctl /out/cloudflared /usr/local/bin/
COPY --from=builder /src/gamja/dist /usr/share/gamja

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf

# 8080: nginx (gamja + WebSocket), public HTTP port on Northflank
# 6667: soju plain IRC, private TCP port (Northflank can't expose TCP publicly)
EXPOSE 8080 6667/tcp

ENTRYPOINT ["/script/entrypoint.sh"]
