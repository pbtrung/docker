#!/bin/sh
set -eu
exec env LD_PRELOAD=/usr/lib/libmimalloc.so.3 \
  weechat -d "${WEECHAT_HOME:-/data/weechat}"
