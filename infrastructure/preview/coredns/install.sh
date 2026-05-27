#!/usr/bin/env bash
# install.sh — install the HA CoreDNS manifest on the preview control-plane.
#
# k3s reads YAML files from /var/lib/rancher/k3s/server/manifests/ and
# applies them via its built-in addon-applier. Replacing coredns.yaml
# there is the supported way to override the bundled CoreDNS addon —
# unlike a kustomize/ArgoCD patch which would fight k3s's owner-set
# reconciliation.
#
# Usage:   ./install.sh [ssh-target]
# Default: martin@ssd

set -euo pipefail

TARGET="${1:-martin@ssd}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/coredns.yaml"
DST="/var/lib/rancher/k3s/server/manifests/coredns.yaml"
BACKUP="/var/lib/rancher/k3s/server/manifests/coredns.yaml.bak-$(date -u +%Y%m%dT%H%M%SZ)"

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: $SRC not found" >&2
  exit 1
fi

echo "==> Uploading new coredns.yaml to $TARGET"
scp -q "$SRC" "$TARGET:/tmp/coredns-new.yaml"

echo "==> Backing up existing manifest and installing new one"
ssh "$TARGET" "
  set -euo pipefail
  if sudo test -f '$DST'; then
    sudo cp '$DST' '$BACKUP'
    echo 'Backed up existing manifest to $BACKUP'
  fi
  sudo install -m 0600 -o root -g root /tmp/coredns-new.yaml '$DST'
  rm -f /tmp/coredns-new.yaml
  echo 'Installed new $DST'
"

echo "==> Waiting for k3s applier (give it ~30 s)…"
sleep 30

echo "==> Verifying"
kubectl --context toxify-preview -n kube-system get deploy coredns -o jsonpath='{.spec.replicas}' && echo
kubectl --context toxify-preview -n kube-system get pods -l k8s-app=kube-dns -o wide

echo
echo "If you see 1 replica, k3s may take up to ~60 s to reapply. Re-run:"
echo "  kubectl --context toxify-preview -n kube-system get deploy coredns"
echo
echo "Rollback:"
echo "  ssh $TARGET sudo install -m 0600 $BACKUP $DST"
