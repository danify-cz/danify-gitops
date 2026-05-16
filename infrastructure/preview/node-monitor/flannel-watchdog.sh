#!/usr/bin/env bash
# flannel-watchdog.sh — restart k3s-agent if flannel.1 interface disappears
# and notify Discord of the self-heal event.
#
# Invoked by flannel-watchdog.timer every 30 s. See README.md in this dir.
#
# Config: source /etc/default/flannel-watchdog (must define DISCORD_WEBHOOK_URL).
# The interface name and CNI subnet wait can be overridden via the same file.

set -uo pipefail

CONFIG_FILE="/etc/default/flannel-watchdog"
if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

IFACE="${FLANNEL_IFACE:-flannel.1}"
RECOVERY_WAIT_SECONDS="${RECOVERY_WAIT_SECONDS:-15}"
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

log() { logger -t flannel-watchdog "$*"; }

notify_discord() {
  local title="$1" status="$2" color="$3"
  if [[ -z "$WEBHOOK_URL" ]]; then
    log "DISCORD_WEBHOOK_URL not set, skipping notification"
    return 0
  fi
  local payload
  payload=$(cat <<EOF
{
  "content": null,
  "embeds": [{
    "title": "${title}",
    "color": ${color},
    "fields": [
      {"name": "Node", "value": "${HOSTNAME_SHORT}", "inline": true},
      {"name": "Interface", "value": "${IFACE}", "inline": true},
      {"name": "Status", "value": "${status}", "inline": true},
      {"name": "Timestamp", "value": "${TIMESTAMP}", "inline": false}
    ]
  }]
}
EOF
)
  curl --silent --show-error --max-time 10 \
    -H "Content-Type: application/json" \
    -X POST "$WEBHOOK_URL" \
    -d "$payload" >/dev/null \
    || log "Discord notification failed (curl exit $?)"
}

if ip link show "$IFACE" >/dev/null 2>&1; then
  exit 0
fi

log "Interface $IFACE missing — restarting k3s-agent"

if ! systemctl restart k3s-agent; then
  log "k3s-agent restart failed"
  notify_discord "Flannel self-heal FAILED" "k3s-agent restart returned non-zero" 15158332
  exit 1
fi

# Give flannel a moment to recreate the interface
sleep "$RECOVERY_WAIT_SECONDS"

if ip link show "$IFACE" >/dev/null 2>&1; then
  log "Interface $IFACE restored after k3s-agent restart"
  notify_discord "Flannel self-heal succeeded" "$IFACE restored after k3s-agent restart" 3066993
else
  log "Interface $IFACE still missing after k3s-agent restart"
  notify_discord "Flannel self-heal FAILED" "$IFACE still missing after k3s-agent restart" 15158332
  exit 1
fi
