# Runbook — Authenticated Origin Pulls (mTLS) pro danify (gh#394 #2)

Cíl: origin (ingress-nginx) přijme provoz **jen z Cloudflare** → znemožní přímý
hit na origin IP `167.235.219.4` a tím i podvržení `CF-Connecting-IP` / `X-Forwarded-For`
(viz danify-app #412 — rate-limit klíčuje podle CF-Connecting-IP, který je
důvěryhodný jen pokud provoz opravdu prošel přes CF).

Proč mTLS a ne IP firewall: Hetzner LB jede k nodům přes privátní IP, node firewall
nevidí klientskou IP (viz `origin-firewall-proxy-protocol-runbook.md`). mTLS to obchází.

> ⚠️ Mění **danify Ingress anotace + secret v ns danify**, NE LB Service →
> netriggeruje hcloud-CCM target-wipe (na rozdíl od proxy-protocolu). danify-gitops
> je v ArgoCD (auto-sync z main) → ingress změnu mergovat AŽ když je hotová CF
> strana + secret, jinak výpadek danify.

## Princip
Po zapnutí AOP na zóně CF posílá originu **klientský cert** (Cloudflare origin-pull
CA). nginx ho vyžaduje a ověří proti té CA. Kdo nemá CF cert (přímý útočník na
origin) → odmítnut.

## Pořadí (DŮLEŽITÉ — jinak výpadek)
1. **CF dashboard NEJDŘÍV** (origin začne posílat cert; nginx zatím neověřuje → neškodné):
   - SSL/TLS → Origin Server → **Authenticated Origin Pulls** → zapnout (zone-level)
     pro zónu `danify.cz`. (Nebo per-hostname pro app/api.)
2. **Vytvořit secret s CF origin-pull CA** v ns `danify`:
   - Stáhnout aktuální CF origin-pull CA PEM z dokumentace Cloudflare
     (https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/ —
     sekce zone-level, „Cloudflare origin pull" CA).
   ```bash
   kubectl --context toxify-prod -n danify create secret generic cloudflare-origin-pull-ca \
     --from-file=ca.crt=origin-pull-ca.pem
   ```
   (Pozn.: pro GitOps čistotu radši jako sealed-secret do danify-gitops; CA je veřejná,
    takže i plain ConfigMap/secret je akceptovatelné — CA není tajná.)
3. **Teprve POTOM** přidat na danify Ingressy anotace (verify proti CA) a mergnout:
   ```yaml
   # environments/prod/ingress.yaml — na danify-ingress i danify-api-ingress:
   nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
   nginx.ingress.kubernetes.io/auth-tls-secret: "danify/cloudflare-origin-pull-ca"
   nginx.ingress.kubernetes.io/auth-tls-verify-depth: "1"
   ```
   Merge → ArgoCD sync → nginx začne ověřovat. Protože CF už cert posílá (krok 1),
   legit provoz projde; přímý hit na origin bez CF certu → 400.

## Verify
```bash
# přes CF — musí fungovat (401/200/404 jako dnes):
for h in danify.cz app.danify.cz api.danify.cz; do
  echo "$h -> $(curl -s -o /dev/null -w '%{http_code}' https://$h/)"; done
# přímý hit na origin BEZ CF certu — musí být odmítnut (400 No required SSL certificate):
curl -s -o /dev/null -w "direct origin -> %{http_code}\n" \
  --resolve app.danify.cz:443:167.235.219.4 https://app.danify.cz/
```

## Rollback
- Odebrat `auth-tls-*` anotace z ingress.yaml → merge → ArgoCD sync (nginx přestane ověřovat).
- (Volitelně) vypnout AOP na CF zóně.
- Žádný dopad na LB/targety.

## Pozn. k záběru
AOP na zone-level ovlivní VŠECHNY hosty zóny danify.cz na tomto ingressu. Pokud by
některý danify host neměl jít přes CF (žádný teď takový není — danify.cz/app/api
jsou všechny proxnuté), použít per-hostname AOP / per-Ingress anotace.

Souvisí: danify-app #412 (CF-Connecting-IP rate-limit), #394.
