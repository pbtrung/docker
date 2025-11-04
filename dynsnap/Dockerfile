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

RUN echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add snapcast-server snapweb@testing \
        wget coreutils sqlite jq rclone ffmpeg opus-tools \
        mosquitto
        
COPY --from=build /root/gwsocket/gwsocket /usr/bin/

WORKDIR /script
COPY entrypoint.sh /script/

ENTRYPOINT ["/script/entrypoint.sh"]
