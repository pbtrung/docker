FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add wget coreutils sqlite jq rclone \
        ffmpeg opus-tools icecast mailcap \
        mosquitto mosquitto-clients

WORKDIR /script
COPY entrypoint.sh /script/

RUN mkdir /music
RUN chown -R icecast:icecast /music
USER icecast

ENTRYPOINT ["/script/entrypoint.sh"]
