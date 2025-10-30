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
WORKDIR /script
COPY entrypoint.sh /script/
RUN mkdir /music
RUN chown -R icecast2:icecast2 /music
USER icecast2
ENTRYPOINT ["/script/entrypoint.sh"]
