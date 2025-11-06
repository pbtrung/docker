FROM alpine:edge AS build

RUN apk update && \
    apk --no-cache upgrade && \
    apk add --no-cache alpine-sdk git pkgconf autoconf automake bash

WORKDIR /root

RUN git clone https://github.com/allinurl/gwsocket && \
    cd gwsocket && \
    autoreconf -fiv && \
    ./configure && \
    make


FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add wget coreutils sqlite jq rclone \
        ffmpeg opus-tools lame icecast \
        mosquitto mosquitto-clients
        
COPY --from=build /root/gwsocket/gwsocket /usr/bin/

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
