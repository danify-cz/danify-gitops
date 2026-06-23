# Postgres backup & restore runbook (gh#418)

Daily encrypted off-site backup of the **production** Postgres database to
Cloudflare R2, plus the step-by-step restore procedure.

> **A backup you have never restored is not a backup.** The restore procedure
> below was validated end-to-end on dev (2026-06-23): dump → encrypt → upload →
> download → decrypt → `pg_restore --list` (289 restorable objects).

---

## 1. What runs, where

| | |
|---|---|
| **What** | `CronJob/postgres-backup` (ns `danify`, prod cluster `toxify-prod` only) |
| **When** | Daily `02:00 Europe/Prague` (`schedule: "0 2 * * *"`, `timeZone` set) |
| **Source** | `pg_dump -Fc` of DB `danify` on service `postgresql:5432` |
| **Encryption** | `age` — client-side, **before** leaving the cluster |
| **Destination** | R2 bucket `danify-db-backups`, key `daily/danify-<UTC-ts>.dump.age` |
| **Retention** | 30 days — enforced by R2 lifecycle rule `expire-30d` (not by the job) |
| **On failure** | `trap ERR` → Discord webhook → `#` channel (silent fail = worst case) |

### Pipeline

```
pg_dump -Fc danify           # custom format, compressed
  → age -r <public key>      # encrypt for the recipient public key
  → rclone copyto r2:danify-db-backups/daily/danify-<ts>.dump.age
  → rclone lsf … (verify object exists)
  any failure → Discord alert
```

The CronJob reads DB credentials from the **same** `postgresql-secret` the
database pod uses (`envFrom`), so user/password/dbname always match the running
server — there is no separate DB password to rotate.

---

## 2. Files (this directory)

| File | Purpose |
|---|---|
| `postgres-backup-cronjob.yaml` | The CronJob |
| `postgres-backup-config.yaml` | ConfigMap — age **public** key, R2 bucket/endpoint, prefix |
| `postgres-backup-sealed-secret.yaml` | SealedSecret — R2 S3 keys + Discord webhook |
| `postgres-backup-runbook.md` | This document |

---

## 3. Secrets & where they live

All backup secrets are centralized in **1Password → Personal → item `danify-db-backup`**:

| Field | Used for |
|---|---|
| `age private key` (`AGE-SECRET-KEY-…`) | **Restore decryption.** NEVER in the cluster — only here. |
| `age public key` (`age1…`) | Encryption recipient — lives plaintext in the ConfigMap |
| `R2 access key id` / `R2 secret access key` | S3 token, scoped to `danify-db-backups` only (Object R&W) |
| `R2 endpoint` / `R2 account id` / `R2 bucket` | R2 target |
| `discord webhook url` | Failure alerts |

> Losing the `age private key` = **all backups become unreadable**. It exists
> only in 1Password. If 1Password is the single point of failure for your DR,
> keep an offline copy somewhere safe (e.g. printed in a safe). Do **not** put
> it in the cluster or in git.

---

## 4. Restore procedure

Prereqs on your workstation: `age`, `wrangler` (logged in: `wrangler login`),
`op` (1Password CLI, signed in), `docker` **or** a local `pg_restore` (v16+).

Export the R2 account id once:

```bash
export CLOUDFLARE_ACCOUNT_ID=9ea0485a9452a594c2b60cdecb0b90fc
```

### 4.1 Find the backup to restore

```bash
# List recent daily backups (newest at the bottom)
wrangler r2 object list danify-db-backups --prefix daily/ --remote
```

Backup keys are timestamped UTC: `daily/danify-YYYYMMDD-HHMMSS.dump.age`.

### 4.2 Download the encrypted dump

```bash
KEY="daily/danify-20260623-020000.dump.age"   # <-- pick the one you want
wrangler r2 object get "danify-db-backups/$KEY" --file /tmp/restore.dump.age --remote
```

### 4.3 Decrypt with the age private key (from 1Password)

```bash
umask 077
op item get danify-db-backup --fields "age private key" --reveal > /tmp/age.key
age -d -i /tmp/age.key -o /tmp/restore.dump /tmp/restore.dump.age
shred -u /tmp/age.key                 # remove the key from disk immediately

# Sanity check — must print PGDMP (custom-format pg_dump magic)
head -c 5 /tmp/restore.dump; echo
```

### 4.4 Inspect before restoring (always do this first)

```bash
# Using docker (no local pg_restore needed):
docker run --rm -v /tmp/restore.dump:/d.dump:ro postgres:16-alpine \
  pg_restore --list /d.dump | grep -vE '^;' | head

# Expect tables: account, invoice, vendor, bank_transaction, taxpayer_profile, …
```

### 4.5a Restore into a THROWAWAY database first (recommended)

Never restore straight over prod. Validate into a scratch DB, eyeball the data,
then decide.

```bash
# Spin a throwaway postgres locally
docker run -d --name pg-restore-test -e POSTGRES_PASSWORD=x -p 55432:5432 postgres:16-alpine
sleep 5

# Restore (custom format → use pg_restore, NOT psql)
docker run --rm --network host -v /tmp/restore.dump:/d.dump:ro postgres:16-alpine \
  pg_restore --no-owner --no-acl -h 127.0.0.1 -p 55432 -U postgres -d postgres \
  --create /d.dump

# Inspect
docker exec -it pg-restore-test psql -U postgres -d danify -c "\dt"
docker exec -it pg-restore-test psql -U postgres -d danify \
  -c "SELECT count(*) FROM invoice;"

# Cleanup
docker rm -f pg-restore-test
```

### 4.5b Restore into PRODUCTION (real disaster recovery)

> ⚠️ Destructive. Only after 4.5a looks right. Put the app into maintenance
> (scale `danify-api` to 0) so nothing writes during the restore.

```bash
# 1. Stop the API so nothing writes mid-restore
kubectl --context toxify-prod -n danify scale deploy/danify-api --replicas=0

# 2. Copy the decrypted dump into the postgres pod
kubectl --context toxify-prod -n danify cp /tmp/restore.dump postgresql-0:/tmp/restore.dump

# 3. Restore. --clean --if-exists drops existing objects first; the DB must
#    already exist (it does — `danify`). For a totally empty cluster, create it:
#    kubectl ... exec postgresql-0 -- psql -U postgres -c 'CREATE DATABASE danify;'
kubectl --context toxify-prod -n danify exec postgresql-0 -- \
  pg_restore --clean --if-exists --no-owner --no-acl \
  -U postgres -d danify /tmp/restore.dump

# 4. Remove the dump from the pod
kubectl --context toxify-prod -n danify exec postgresql-0 -- rm -f /tmp/restore.dump

# 5. Bring the API back
kubectl --context toxify-prod -n danify scale deploy/danify-api --replicas=1

# 6. Verify app health + spot-check data in the UI
```

### 4.6 Clean up local artifacts

```bash
rm -f /tmp/restore.dump /tmp/restore.dump.age
```

---

## 5. Operating notes

### Trigger an ad-hoc backup (don't wait for 02:00)

```bash
kubectl --context toxify-prod -n danify create job --from=cronjob/postgres-backup \
  postgres-backup-manual-$(date +%s)
kubectl --context toxify-prod -n danify logs -f job/<name>
```

### Check the last runs

```bash
kubectl --context toxify-prod -n danify get jobs -l app.kubernetes.io/name=postgres-backup
kubectl --context toxify-prod -n danify get cronjob postgres-backup
```

### Did it actually upload?

```bash
wrangler r2 object list danify-db-backups --prefix daily/ --remote | tail
```

---

## 6. Known limitations / future work

- **Granularity = 24h.** Worst case you lose up to a day of data. Continuous
  PITR (wal-g / pgBackRest / CloudNativePG) is **Fáze 2** of gh#418.
- **CronJob runs as root** to `apk add` the tooling at runtime (network
  dependency on the Alpine CDN). Fáze-2 hardening: prebuilt image with
  `pg_dump` + `age` + `rclone` baked in → drop root, no runtime install.
- **Single encryption key.** The `age private key` lives only in 1Password.
  Keep an offline backup of it — without it, every backup is unreadable.
- **No success heartbeat.** Alerts fire only on failure. If you want a daily
  "✅ backup OK" ping, add a success `notify` at the end of the job script.
- **Retention is R2-side.** The 30-day `expire-30d` lifecycle rule deletes old
  objects; the job itself never prunes. To change retention, edit the lifecycle
  rule (`wrangler r2 bucket lifecycle …`), not the CronJob.
