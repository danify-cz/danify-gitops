# CoreDNS HA — preview cluster

Scales the bundled k3s CoreDNS addon from 1 → 2 replicas with soft
node-spread for the preview cluster (`toxify-preview`). Background:
[danify-cz/danify-app#127](https://github.com/danify-cz/danify-app/issues/127).

## Why bypass ArgoCD

K3s ships CoreDNS as an addon and writes the Deployment with
`objectset.rio.cattle.io/owner-name: coredns`. Its built-in
addon-applier periodically reconciles the resource back to whatever
sits in `/var/lib/rancher/k3s/server/manifests/coredns.yaml` on the
control-plane node. A kustomize / ArgoCD patch would enter a sync
fight with this controller.

The supported way to override the addon is to **replace the source
manifest on the control-plane**. K3s then makes our version the
canonical state and keeps it stable across server restarts.

## What changed vs. upstream k3s default

| Setting | Before | After | Why |
|---|---|---|---|
| `Deployment.spec.replicas` | `1` (implicit) | `2` | Removes single-replica SPOF |
| `topologySpreadConstraints[0].whenUnsatisfiable` (hostname) | `DoNotSchedule` | `ScheduleAnyway` | Lets the second replica schedule even when only one host is currently eligible (e.g. during a node flap) |
| `affinity.podAntiAffinity` | absent | preferredDuringScheduling, weight 100, hostname topology | Soft preference to place replicas on different nodes |

Image, resources, RBAC, Corefile, Service, etc. — all unchanged from
upstream `rancher/mirrored-coredns-coredns:1.13.1` shipped by k3s
v1.34.3.

## Install

From your laptop:

```bash
./install.sh           # defaults to martin@ssd
# or
./install.sh martin@ssd
```

The script:

1. `scp`s the new manifest to `/tmp/coredns-new.yaml` on `ssd`
2. Backs up the existing `/var/lib/rancher/k3s/server/manifests/coredns.yaml`
   to `coredns.yaml.bak-<UTC timestamp>`
3. Installs the new manifest (`install -m 0600 -o root`)
4. Waits ~30 s and runs `kubectl get deploy coredns` + `pods -o wide`

## Verify

```bash
kubectl --context toxify-preview -n kube-system get deploy coredns
# NAME      READY   UP-TO-DATE   AVAILABLE   AGE
# coredns   2/2     2            2           ...

kubectl --context toxify-preview -n kube-system get pods -l k8s-app=kube-dns -o wide
# NAME                       READY   STATUS    NODE
# coredns-xxxxxxxx-aaaaa     1/1     Running   ssdnodes-storage1
# coredns-xxxxxxxx-bbbbb     1/1     Running   srv748299
```

Both pods should land on different nodes. If they end up co-located,
soft anti-affinity still allowed scheduling — that's expected if one
node is briefly under taint/pressure. The next scheduler pass will
re-balance.

## Smoke test (failover)

```bash
# Delete the coredns pod on storage1 — should reschedule fast,
# leaving the other replica serving DNS during the gap.
kubectl --context toxify-preview -n kube-system delete pod \
  -l k8s-app=kube-dns --field-selector spec.nodeName=ssdnodes-storage1

# In another terminal, hit DNS continuously:
while true; do
  kubectl --context toxify-preview -n danify run dns-probe --rm -i \
    --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default \
    2>&1 | grep -E 'Address|connection timed out' | head -2
  sleep 1
done
```

No "connection timed out" lines should appear.

## Rollback

The installer prints the exact backup path. To roll back:

```bash
ssh martin@ssd 'sudo install -m 0600 \
  /var/lib/rancher/k3s/server/manifests/coredns.yaml.bak-<TS> \
  /var/lib/rancher/k3s/server/manifests/coredns.yaml'
```

K3s re-applies within ~30 s, scaling back to 1 replica.

## Future maintenance

When k3s ships an update to its bundled `coredns.yaml`:

1. Pull the new upstream from
   `/var/lib/rancher/k3s/server/manifests/coredns.yaml` after the k3s
   binary upgrade (k3s rewrites it during install/upgrade unless the
   file diverged — in that case it leaves your version alone, but the
   new bundled one lives at `coredns.yaml.skip` for reference).
2. Diff against `coredns.yaml` in this repo, port the three reliability
   changes onto the new base, commit, run `install.sh` again.
