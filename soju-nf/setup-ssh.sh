#!/bin/sh
set -eu

: "${SSH_PUBLIC_KEY:?Set SSH_PUBLIC_KEY to your Ed25519 public key}"
SSH_USERNAME="${SSH_USERNAME:-soju}"
case "$SSH_USERNAME" in
  [a-z_]*) ;;
  *) printf 'Invalid SSH_USERNAME\n' >&2; exit 1 ;;
esac
case "$SSH_USERNAME" in
  *[!a-z0-9_-]*) printf 'Invalid SSH_USERNAME\n' >&2; exit 1 ;;
esac
if [ "${#SSH_USERNAME}" -gt 32 ]; then
  printf 'SSH_USERNAME must be at most 32 characters\n' >&2
  exit 1
fi
# Accept one bare Ed25519 key, with an optional comment and blank lines.
# TinySSH does not support OpenSSH authorized_keys options.
if ! printf '%s\n' "$SSH_PUBLIC_KEY" | awk '
  NF {
    count++
    if ($1 != "ssh-ed25519" || length($2) != 68 ||
        $2 !~ /^AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+\/]+$/) invalid=1
  }
  END { exit (count != 1 || invalid) }
'; then
  printf 'SSH_PUBLIC_KEY must contain one bare Ed25519 public key\n' >&2
  exit 1
fi

# Keep the service account for WeeChat and alias its UID for SSH access.
# Refuse existing system users instead of assigning them the login key.
if [ "$SSH_USERNAME" != soju ]; then
  if awk -F: -v name="$SSH_USERNAME" '$1 == name { found=1 } END { exit !found }' /etc/passwd; then
    if ! awk -F: -v name="$SSH_USERNAME" '
      $1 == name && $3 == 1000 && $4 == 1000 && $6 == "/data" && $7 == "/bin/ash" { valid=1 }
      END { exit !valid }
    ' /etc/passwd; then
      printf 'SSH_USERNAME conflicts with an existing system account\n' >&2
      exit 1
    fi
  else
    printf '%s:x:1000:1000::/data:/bin/ash\n' "$SSH_USERNAME" >>/etc/passwd
    printf '%s:!:0:0:99999:7:::\n' "$SSH_USERNAME" >>/etc/shadow
  fi
fi

# Never write to a user-writable home as root. Replacing authorized_keys
# also prevents a hard link there from redirecting the write.
printf '%s\n' "$SSH_PUBLIC_KEY" | su-exec soju sh -eu -c '
  umask 077
  # TinySSH checks the ownership and write permissions of the home path.
  chmod go-w /data
  if [ -L /data/.ssh ]; then
    printf "/data/.ssh is a symbolic link; refusing SSH setup\n" >&2
    exit 1
  fi
  mkdir -p /data/.ssh
  chmod 700 /data/.ssh
  rm -f /data/.ssh/authorized_keys
  cat > /data/.ssh/authorized_keys
  chmod 600 /data/.ssh/authorized_keys
'

# Host private keys stay outside the volume owned by the SSH login.
mkdir -p /etc/tinyssh
chmod 700 /etc/tinyssh
if [ ! -d /etc/tinyssh/sshkeydir ]; then
  tinysshd-makekey /etc/tinyssh/sshkeydir
fi
printf 'TinySSH login configured for %s on 127.0.0.1:22\n' "$SSH_USERNAME"
