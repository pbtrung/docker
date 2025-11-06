FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add wget coreutils sqlite jq rclone \
        ffmpeg opus-tools lame icecast \
        mosquitto mosquitto-clients

RUN dd if=/dev/zero bs=2205000 count=1 \
        | lame -r -b 128 -m s \
          --ta "silence" \
          --tt "silence" \
        - silence.mp3 && \
    mv silence.mp3 /usr/share/icecast/web/

WORKDIR /script
COPY entrypoint.sh /script/

RUN mkdir /music
RUN chown -R icecast:icecast /music
USER icecast

ENTRYPOINT ["/script/entrypoint.sh"]
