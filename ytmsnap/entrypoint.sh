#!/bin/ash

set -eu
cp /music/run.sh /music/stream.sh
chmod +x /music/stream.sh
/music/stream.sh
