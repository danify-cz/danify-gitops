# ArgoCD Notifications

Discord notifications for deployment status.

## Setup

### 1. Apply ConfigMap to both clusters

```bash
# Dev cluster (handles dev + preview)
kubectl --context toxify-dev apply -f configmap.yaml

# Prod cluster
kubectl --context toxify-prod apply -f configmap.yaml
```

### 2. Apply SealedSecrets

```bash
# Dev cluster (dev/preview Discord channel)
kubectl --context toxify-dev apply -f secret-dev.sealed.yaml

# Prod cluster (prod Discord channel)
kubectl --context toxify-prod apply -f secret-prod.sealed.yaml
```

### 3. Re-apply ArgoCD Applications

```bash
# Dev cluster
kubectl --context toxify-dev apply -f ../../apps/dev/danify.yaml
kubectl --context toxify-dev apply -f ../../apps/preview/danify.yaml

# Prod cluster
kubectl --context toxify-prod apply -f ../../apps/prod/danify.yaml
```

## Discord Channels

| Environment | Channel |
|-------------|---------|
| Dev + Preview | #danify-dev-deployments |
| Production | #danify-prod-deployments |

## Notification Triggers

| Trigger | When | Message |
|---------|------|---------|
| on-deployed | Sync succeeded | ✅ Deployment succeeded |
| on-sync-failed | Sync failed | ❌ Sync failed with error |
| on-health-degraded | Health degraded | ⚠️ Health degraded |

## Regenerating Secrets

If webhook URLs change, regenerate sealed secrets:

```bash
# Dev webhook
cat <<'EOF' | kubeseal --controller-namespace=kube-system --controller-name=sealed-secrets-controller --context toxify-dev --format yaml > secret-dev.sealed.yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-notifications-secret
  namespace: argocd
type: Opaque
stringData:
  discord-webhook-url: "NEW_DEV_WEBHOOK_URL"
EOF

# Prod webhook
cat <<'EOF' | kubeseal --controller-namespace=kube-system --controller-name=sealed-secrets-controller --context toxify-prod --format yaml > secret-prod.sealed.yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-notifications-secret
  namespace: argocd
type: Opaque
stringData:
  discord-webhook-url: "NEW_PROD_WEBHOOK_URL"
EOF
```
