# Danify GitOps

GitOps repository for Danify Kubernetes deployments using Kustomize and ArgoCD.

## Structure

```
danify-gitops/
├── apps/                           # ArgoCD Application definitions
│   ├── dev/danify.yaml            # Dev environment app
│   ├── preview/danify.yaml        # Preview environment app
│   └── prod/danify.yaml           # Production environment app
│
├── environments/                   # Kubernetes manifests
│   ├── base/                      # Shared base configurations
│   │   ├── danify-landing/        # Landing page
│   │   ├── danify-fe/             # Frontend app
│   │   ├── danify-be/             # Backend API
│   │   └── postgresql/            # Database
│   ├── dev/                       # Dev overlay (dev.danify.cz:9443)
│   ├── preview/                   # Preview overlay (preview.danify.cz)
│   └── prod/                      # Production overlay (danify.cz)
│
└── infrastructure/                 # Cluster infrastructure
    ├── namespace.yaml
    ├── ghcr-secret-template.yaml
    ├── sealed-secrets/
    └── certificates/
```

## Environments

| Environment | Landing | Frontend | Backend |
|-------------|---------|----------|---------|
| Dev | dev.danify.cz:9443 | app.dev.danify.cz:9443 | api.dev.danify.cz:9443 |
| Preview | preview.danify.cz | app.preview.danify.cz | api.preview.danify.cz |
| Production | danify.cz | app.danify.cz | api.danify.cz |

## Docker Images

| Image | GHCR Path |
|-------|-----------|
| Landing | ghcr.io/danify-cz/danify-landing |
| Frontend | ghcr.io/danify-cz/danify-fe |
| Backend | ghcr.io/danify-cz/danify-api |

## Deployment Flow

```
main branch → dev environment (auto)
     ↓
release branch → preview environment (auto)
     ↓
manual dispatch → production environment
```

## Prerequisites

1. Kubernetes cluster with:
   - nginx-ingress-controller
   - cert-manager
   - ArgoCD

2. GHCR pull secret configured in each environment

3. Cloudflare API token for DNS challenge (dev/preview)

## Deploying to ArgoCD

```bash
# Apply ArgoCD application for dev
kubectl apply -f apps/dev/danify.yaml

# Apply ArgoCD application for preview
kubectl apply -f apps/preview/danify.yaml

# Apply ArgoCD application for prod
kubectl apply -f apps/prod/danify.yaml
```

## Manual Kustomize build

```bash
# Build dev manifests
kustomize build environments/dev

# Build preview manifests
kustomize build environments/preview

# Build prod manifests
kustomize build environments/prod
```
