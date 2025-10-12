#!/bin/ash

# Exit on error
set -eu

snapserver --config "/music/snapserver.conf" &

while true; do
    line=$(shuf -n 1 /music/db01.txt)
    first=$(echo "$line" | cut -d',' -f1)
    second=$(echo "$line" | cut -d',' -f2)
    fname=${first##*/}
    fullname="/music/downloads/$fname"

    rclone --config /music/rclone.conf copy $first /music/downloads/ -v --stats 5s
    opusdec $fullname --rate 48000 - | \
        ffmpeg -y -i - -af "dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0" \
        -f s16le -acodec pcm_s16le -ac 2 -ar 48000 /tmp/snapfifo
    rm -f $fullname

    sleep 1
done
