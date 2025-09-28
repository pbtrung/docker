FROM alpine:edge

RUN echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add snapcast-server snapweb@testing librespot@testing \
        wget yt-dlp jq sqlite ffmpeg coreutils

WORKDIR /script
COPY entrypoint.sh /script/

ENTRYPOINT ["/script/entrypoint.sh"]
