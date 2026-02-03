# Sealed Secrets

This directory contains sealed secrets templates for each environment.

## How to create sealed secrets

1. Install kubeseal CLI
2. Get the public key from your cluster:
   ```bash
   kubeseal --fetch-cert --controller-name=sealed-secrets --controller-namespace=kube-system > pub-cert.pem
   ```

3. Create a secret and seal it:
   ```bash
   kubectl create secret generic my-secret \
     --from-literal=key=value \
     --namespace=danify \
     --dry-run=client -o yaml | \
     kubeseal --cert pub-cert.pem --format yaml > sealed-secret.yaml
   ```

## Environment-specific secrets

Each environment (dev, preview, prod) should have its own sealed secrets:
- `dev/` - Development environment secrets
- `preview/` - Preview/staging environment secrets
- `prod/` - Production environment secrets

## Required secrets per environment

1. `ghcr-pull-secret` - GHCR registry credentials
2. `postgresql-secret` - Database credentials (should override base)
3. `danify-api-secret` - API application secrets (DATABASE_URL, BETTER_AUTH_SECRET, etc.)
