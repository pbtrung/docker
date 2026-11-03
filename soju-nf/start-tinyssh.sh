#!/bin/sh
# BusyBox inetd connects stdin, stdout AND stderr to the accepted socket.
# Keep diagnostics out of the SSH protocol, including errors from exec.
exec 2>/proc/1/fd/2
exec /usr/sbin/tinysshd -v /etc/tinyssh/sshkeydir
