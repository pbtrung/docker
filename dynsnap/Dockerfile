FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add wget coreutils sqlite jq rclone \
        ffmpeg opus-tools icecast mailcap \
        mosquitto mosquitto-clients

RUN dd if=/dev/zero bs=960000 count=1 \
        | opusenc --bitrate 256 --raw \
        --artist "silence" \
        --title "silence" \
        - silence.opus && \
    mv silence.opus /usr/share/icecast/web/

WORKDIR /script
COPY entrypoint.sh /script/

RUN mkdir /music
RUN chown -R icecast:icecast /music
USER icecast

ENTRYPOINT ["/script/entrypoint.sh"]
