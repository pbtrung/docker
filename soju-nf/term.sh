# Fallback for telnet clients without a useful terminal type.
case "${TERM:-}" in
  ''|dumb) export TERM=xterm ;;
esac
