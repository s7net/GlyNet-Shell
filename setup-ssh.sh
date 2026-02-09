#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

PUBKEY="${1:-}"
if [[ -z "$PUBKEY" ]]; then
  echo "Usage: $0 'ssh-ed25519 AAAA... comment'" >&2
  exit 1
fi
if [[ "$PUBKEY" != ssh-* ]]; then
  echo "ERROR: invalid pubkey (must start with ssh-)" >&2
  exit 1
fi

umask 077
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
grep -qxF "$PUBKEY" /root/.ssh/authorized_keys || echo "$PUBKEY" >> /root/.ssh/authorized_keys

CFG="/etc/ssh/sshd_config"
BK="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CFG" "$BK"

if grep -qE '^[#[:space:]]*PubkeyAuthentication' "$CFG"; then
  sed -i -E 's/^[#[:space:]]*PubkeyAuthentication[[:space:]]+.*/PubkeyAuthentication yes/' "$CFG"
else
  echo 'PubkeyAuthentication yes' >> "$CFG"
fi

sshd -t

# Reload/restart (best effort)
systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || \
systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || \
service ssh reload 2>/dev/null || service ssh restart 2>/dev/null || true

echo "OK: key installed + PubkeyAuthentication enabled. Backup: $BK"
