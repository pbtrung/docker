FROM archlinux:latest

ARG RSAS_VERSION=1.0.7
ARG RSAS_URL=https://www.rocketbroadcaster.com/streaming-audio-server/downloads/ubuntu-14.04/rsas-${RSAS_VERSION}-linux_amd64.tar.gz

RUN pacman --noconfirm -Syu && \
    pacman --noconfirm -S wget sqlite jq rclone \
        ffmpeg opus-tools mosquitto

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

RUN dd if=/dev/zero bs=960000 count=1 \
        | opusenc --bitrate 256 --raw \
        --artist "silence" \
        --title "silence" \
        - silence.opus && \
    mv silence.opus /usr/share/rsas/webroot/

WORKDIR /script
COPY entrypoint.sh /script/
RUN chmod +x /script/entrypoint.sh && \
    mkdir -p /music && \
    chown -R rsas:rsas /music /script

USER rsas

ENTRYPOINT ["/script/entrypoint.sh"]
