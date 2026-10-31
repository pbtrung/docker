#!/bin/sh
set -eu
umask 077
exec env LD_PRELOAD=/usr/lib/libmimalloc.so.3 irssi --home=/data/irssi
