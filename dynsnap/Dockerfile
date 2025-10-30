FROM ubuntu:rolling AS build

ARG GWSOCKET_REPO=https://github.com/allinurl/gwsocket

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y \
        build-essential \
        git \
        pkg-config \
        autoconf \
        automake \
        bash && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone ${GWSOCKET_REPO} && \
    cd gwsocket && \
    autoreconf -fiv && \
    ./configure && \
    make && \
    strip gwsocket

FROM ubuntu:rolling

ARG RSAS_VERSION=1.0.7
ARG RSAS_URL=https://www.rocketbroadcaster.com/streaming-audio-server/downloads/ubuntu-14.04/rsas-${RSAS_VERSION}-linux_amd64.tar.gz

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y \
        wget \
        coreutils \
        sqlite3 \
        jq \
        rclone \
        ffmpeg && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /build/gwsocket/gwsocket /usr/bin/gwsocket

RUN wget ${RSAS_URL} && \
    tar -xzf rsas-${RSAS_VERSION}-linux_amd64.tar.gz && \
    cd rsas-${RSAS_VERSION}-linux_amd64 && \
    sed -i 's/SYSTEMD=1/SYSTEMD=0/g' install.sh && \
    sed -i 's/addgroup --system --quiet/groupadd -r/g' install.sh && \
    sed -i 's/adduser --system --quiet --disabled-password --disabled-login/useradd -r -s \/bin\/false/g' install.sh && \
    sed -i 's/--home \/usr\/share\/rsas\/webroot --no-create-home --ingroup rsas/-d \/usr\/share\/rsas\/webroot -M -g rsas/g' install.sh && \
    ./install.sh && \
    cd .. && \
    rm -rf rsas-${RSAS_VERSION}-linux_amd64.tar.gz rsas-${RSAS_VERSION}-linux_amd64

WORKDIR /script
COPY entrypoint.sh /script/
RUN chmod +x /script/entrypoint.sh && \
    mkdir -p /music && \
    chown -R rsas:rsas /music /script

USER rsas

ENTRYPOINT ["/script/entrypoint.sh"]
