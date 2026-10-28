#!/bin/sh
set -eu

exec env LD_PRELOAD=/usr/lib/libmimalloc.so.3 \
  weechat --dir "$WEECHAT_HOME" \
    --plugins '*,!relay,!python,!perl,!ruby,!lua,!tcl,!guile,!javascript,!php,!xfer' \
    --run-command "$WEECHAT_STARTUP_COMMANDS"
