FROM alpine:edge AS builder

ARG GLOWING_BEAR_REF=latest

RUN apk update && \
    apk --no-cache upgrade

# cloudflared: official static release binary (no Alpine package)
RUN mkdir -p /out && \
    wget -q -O /out/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /out/cloudflared

# Glowing Bear: prebuilt release from pbtrung/glowing-bear, seeded into
# /data/glowing-bear on first start
COPY update-glowing-bear.sh /usr/local/bin/
RUN GLOWING_BEAR_DIR=/out/glowing-bear \
      update-glowing-bear.sh "${GLOWING_BEAR_REF}"

FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata mailcap nginx su-exec \
      weechat weechat-perl weechat-python weechat-lua

RUN addgroup -g 1000 weechat && \
    adduser -u 1000 -G weechat -D weechat

COPY --from=builder /out/cloudflared /usr/local/bin/
COPY --from=builder /out/glowing-bear /usr/share/glowing-bear-dist

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf
COPY weechat-cmd /usr/local/bin/weechat-cmd
COPY update-glowing-bear.sh /usr/local/bin/update-glowing-bear.sh

# 8080: nginx (Glowing Bear + relay WebSocket), public HTTP port on Northflank.
# The WeeChat relay itself listens on 127.0.0.1:9001 only.
EXPOSE 8080

ENTRYPOINT ["/script/entrypoint.sh"]
