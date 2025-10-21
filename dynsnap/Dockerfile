FROM alpine:edge AS build

RUN apk update && \
    apk --no-cache upgrade && \
    apk add --no-cache alpine-sdk git pkgconf autoconf automake bash sed

WORKDIR /root

RUN git clone https://github.com/allinurl/gwsocket && \
    cd gwsocket && \
    autoreconf -fiv && \
    ./configure && \
    make

RUN git clone https://github.com/MestreLion/wavegain && \
    cd wavegain && \
    sed -i 's/CFLAGS  += -m32/CFLAGS  += -fcommon/g' Makefile && \
    rm getopt.c getopt1.c getopt.h && \
    make


FROM alpine:edge

RUN echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add snapcast-server snapweb@testing \
        wget coreutils gawk sqlite jq rclone opus-tools

COPY --from=build /root/gwsocket/gwsocket /usr/bin/
COPY --from=build /root/wavegain/wavegain /usr/bin/

WORKDIR /script
COPY entrypoint.sh /script/

ENTRYPOINT ["/script/entrypoint.sh"]