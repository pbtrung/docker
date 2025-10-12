#!/bin/ash

# Exit on error
set -eu

snapserver --config "/music/snapserver.conf" &

while true; do
    line=$(shuf -n 1 /music/db01.txt)
    first=$(echo "$line" | cut -d',' -f1)
    second=$(echo "$line" | cut -d',' -f2)
    binname=${first##*/}
    fname="${binname%.bin}.opus"
    fullname="/music/downloads/$fname"

    rclone --config /music/rclone.conf copy $first $fullname -v --stats 5s
    dynaudnorm --input-bits 16 --input-chan 2 --input-rate 48000 -i $fullname -o /tmp/snapfifo
    rm -f $fullname

    sleep 1
done
