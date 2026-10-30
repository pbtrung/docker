#!/bin/sh
# Installed as /usr/local/bin/soju and /usr/local/bin/sojuctl: runs the
# soju binary of the same name with the container's config file. A
# -config given on the command line still wins (the last one is used).
exec "/usr/local/lib/soju/$(basename "$0")" -config "${SOJU_CONF:-/etc/soju/config}" "$@"
