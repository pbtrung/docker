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
        wget coreutils gawk grep sqlite jq rclone \
        ffmpeg icecast
    # apk --no-cache add snapcast-server snapweb@testing \
    #     wget coreutils gawk grep sqlite jq rclone \
    #     gst-plugins-base gst-plugins-good ffmpeg
        
COPY --from=build /root/gwsocket/gwsocket /usr/bin/

WORKDIR /script
COPY entrypoint.sh /script/

RUN addgroup -S icecast2 && adduser -S -G icecast2 icecast2
USER icecast2

ENTRYPOINT ["/script/entrypoint.sh"]
