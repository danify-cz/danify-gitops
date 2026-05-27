#!/usr/bin/env bash
# install.sh — install flannel-watchdog on a single remote node.
#
# Usage:   ./install.sh <ssh-target>
# Example: ./install.sh martin@hostinger
#          ./install.sh martin@hostinger2
#
# Prereqs:
#   - Passwordless sudo on the remote (or interactive sudo prompt)
#   - DISCORD_WEBHOOK_URL exported locally; the installer writes it
#     into /etc/default/flannel-watchdog on the node. The file is NOT
#     committed to the repo.

set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <ssh-target>" >&2
  exit 1
fi

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  echo "ERROR: DISCORD_WEBHOOK_URL is not set in the local environment." >&2
  echo "       Export it first:  export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Uploading watchdog files to $TARGET"
scp -q \
  "$SCRIPT_DIR/flannel-watchdog.sh" \
  "$SCRIPT_DIR/flannel-watchdog.service" \
  "$SCRIPT_DIR/flannel-watchdog.timer" \
  "$TARGET:/tmp/"

echo "==> Installing on $TARGET"
ssh "$TARGET" "
  set -euo pipefail
  sudo install -m 0755 /tmp/flannel-watchdog.sh /usr/local/sbin/flannel-watchdog.sh
  sudo install -m 0644 /tmp/flannel-watchdog.service /etc/systemd/system/flannel-watchdog.service
  sudo install -m 0644 /tmp/flannel-watchdog.timer /etc/systemd/system/flannel-watchdog.timer

  # Write the webhook URL (chmod 0600 — root-only readable)
  sudo install -m 0600 /dev/stdin /etc/default/flannel-watchdog <<EOF
# Managed by danify-gitops flannel-watchdog installer
DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now flannel-watchdog.timer
  rm -f /tmp/flannel-watchdog.sh /tmp/flannel-watchdog.service /tmp/flannel-watchdog.timer

  echo
  echo '== systemctl list-timers flannel-watchdog.timer =='
  systemctl list-timers flannel-watchdog.timer --no-pager
"

echo "==> Done on $TARGET"
