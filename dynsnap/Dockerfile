FROM alpine:edge AS build

RUN apk update && \
    apk --no-cache upgrade && \
    apk add --no-cache alpine-sdk git pkgconf autoconf automake bash \
        libsndfile-dev opus-dev opusfile-dev mpg123-dev

WORKDIR /root

RUN git clone https://github.com/allinurl/gwsocket && \
    cd gwsocket && \
    autoreconf -fiv && \
    ./configure && \
    make

RUN git clone https://github.com/pbtrung/dynaudnorm && \
    cd dynaudnorm && \
    make MODE=minimal && \
    mv bin/*/DynamicAudioNormalizerCLI.bin dynaudnorm && \
    mv bin/*/libDynamicAudioNormalizerAPI-8.so .

FROM alpine:edge

RUN echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add jq snapcast-server snapweb@testing \
        rclone libsndfile opus opusfile mpg123-libs opus-tools

COPY --from=build /root/gwsocket/gwsocket /usr/bin/
COPY --from=build /root/dynaudnorm/dynaudnorm /usr/bin/
COPY --from=build /root/dynaudnorm/*.so /usr/lib/

WORKDIR /script
COPY entrypoint.sh /script/

ENTRYPOINT ["/script/entrypoint.sh"]