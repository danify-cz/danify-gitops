# TLS Certificates

This directory contains cert-manager configuration for TLS certificates.

## ClusterIssuers

The following ClusterIssuers should be configured in the cluster:

### Production (HTTP-01 challenge)
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
```

### Cloudflare DNS challenge (for dev/preview behind Tailscale)
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-cloudflare
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-cloudflare
    solvers:
      - dns01:
          cloudflare:
            email: your-cloudflare-email@example.com
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

## Required Cloudflare secret

For dev/preview environments, create a secret with your Cloudflare API token:

```bash
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN \
  --namespace=cert-manager
```

The API token needs Zone:DNS:Edit permissions for the danify.cz zone.
