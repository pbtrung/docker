FROM alpine:edge AS builder

ARG GLOWING_BEAR_REF=master

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add git nodejs npm

RUN git clone --depth 1 --branch "${GLOWING_BEAR_REF}" https://github.com/glowing-bear/glowing-bear.git /src/glowing-bear

# cloudflared: official static release binary (no Alpine package)
RUN mkdir -p /out && \
    wget -q -O /out/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /out/cloudflared

# Glowing Bear: static web client, built into build/
WORKDIR /src/glowing-bear
RUN npm ci && \
    npm run build

FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add ca-certificates tzdata mailcap nginx su-exec \
      weechat weechat-perl weechat-python weechat-lua

RUN addgroup -g 1000 weechat && \
    adduser -u 1000 -G weechat -D weechat

COPY --from=builder /out/cloudflared /usr/local/bin/
COPY --from=builder /src/glowing-bear/build /usr/share/glowing-bear

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf
COPY weechat-cmd /usr/local/bin/weechat-cmd

# 8080: nginx (Glowing Bear + relay WebSocket), public HTTP port on Northflank.
# The WeeChat relay itself listens on 127.0.0.1:9001 only.
EXPOSE 8080

ENTRYPOINT ["/script/entrypoint.sh"]
