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
        ffmpeg icecast
        
COPY --from=build /root/gwsocket/gwsocket /usr/bin/

WORKDIR /script
COPY entrypoint.sh /script/

RUN mkdir /music
RUN chown -R icecast:icecast /music
USER icecast

ENTRYPOINT ["/script/entrypoint.sh"]
