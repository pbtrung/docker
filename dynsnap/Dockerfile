FROM ubuntu:devel AS build
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y build-essential git pkg-config autoconf automake bash
WORKDIR /root
RUN git clone https://github.com/allinurl/gwsocket && \
    cd gwsocket && \
    autoreconf -fiv && \
    ./configure && \
    make

FROM ubuntu:devel
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y wget coreutils sqlite3 jq rclone \
        ffmpeg icecast2 opus-tools mpg123 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
        
COPY --from=build /root/gwsocket/gwsocket /usr/bin/

RUN wget https://www.rocketbroadcaster.com/streaming-audio-server/downloads/ubuntu-14.04/rsas-1.0.7-linux_amd64.tar.gz && \
    tar -xvzf rsas-1.0.7-linux_amd64.tar.gz && \
    cd rsas-1.0.7-linux_amd64 && \
    ./install.sh

WORKDIR /script
COPY entrypoint.sh /script/

RUN mkdir /music
RUN chown -R rsas:rsas /music
USER rsas
ENTRYPOINT ["/script/entrypoint.sh"]
