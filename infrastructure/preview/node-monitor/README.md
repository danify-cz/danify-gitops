# flannel-watchdog — preview cluster self-heal

Per-node systemd timer that restarts `k3s-agent` whenever the
`flannel.1` VXLAN interface disappears, and posts a Discord embed
to record each self-heal event. Background: see
[danify-cz/danify-app#127](https://github.com/danify-cz/danify-app/issues/127).

## What it does

1. `flannel-watchdog.timer` fires every 30 s and triggers
   `flannel-watchdog.service`.
2. The service runs `/usr/local/sbin/flannel-watchdog.sh`.
3. If `flannel.1` exists → exit 0 (no-op, no Discord noise).
4. If `flannel.1` is missing →
   - log `Interface flannel.1 missing — restarting k3s-agent` via syslog;
   - `systemctl restart k3s-agent`;
   - wait 15 s, re-check `flannel.1`;
   - POST a Discord embed (green if recovered, red if still missing).

Recovery typically completes within 30–60 s from the moment the
interface goes away.

## Files

| File | Installed to | Purpose |
|---|---|---|
| `flannel-watchdog.sh` | `/usr/local/sbin/flannel-watchdog.sh` (0755) | Self-heal logic |
| `flannel-watchdog.service` | `/etc/systemd/system/flannel-watchdog.service` (0644) | `oneshot` driver |
| `flannel-watchdog.timer` | `/etc/systemd/system/flannel-watchdog.timer` (0644) | 30 s schedule |
| `install.sh` | run locally on your machine | Pushes everything over SSH |

The webhook URL and any per-node overrides live in
`/etc/default/flannel-watchdog` (mode `0600`), written by the installer
from the `DISCORD_WEBHOOK_URL` environment variable. **Not committed.**

## Install

Run from your laptop, once per worker node:

```bash
export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/<id>/<token>'

./install.sh martin@hostinger
./install.sh martin@hostinger2
```

The control-plane node (`ssd`) **does not need this** — `flannel.1`
lives on workers only. If a future change moves flannel to all nodes,
re-run on `ssd` too.

## Verify

On each worker:

```bash
ssh martin@hostinger systemctl list-timers flannel-watchdog.timer --no-pager
# NEXT                        LEFT     LAST                        PASSED        UNIT
# Sat 2026-05-17 18:00:30 ... 12s left Sat 2026-05-17 18:00:00 ... 18s ago       flannel-watchdog.timer

ssh martin@hostinger systemctl status flannel-watchdog.service --no-pager
# Should show "Active: inactive (dead)" between runs — that's correct for a Type=oneshot.
```

## Smoke test (controlled failure)

Simulate the failure mode that caused the original incident:

```bash
ssh martin@hostinger2 sudo ip link delete flannel.1
# Within ~30 s: timer fires → watchdog restarts k3s-agent → flannel.1 reappears.

ssh martin@hostinger2 'ip -br a | grep flannel'
# flannel.1        UNKNOWN        10.42.2.0/32
```

A green Discord embed should arrive in `#danify-dev-deployments`
(or whichever channel the webhook points at).

## View self-heal history

```bash
ssh martin@hostinger journalctl -t flannel-watchdog --since='24h ago' --no-pager
```

If you see more than 2 self-heals per hour over the course of a day,
that's a signal to investigate the underlying cause (Tailscale, kernel,
k3s upgrade) — open a follow-up task on
[#127](https://github.com/danify-cz/danify-app/issues/127).

## Rollback

```bash
ssh martin@hostinger 'sudo systemctl disable --now flannel-watchdog.timer && \
                      sudo rm -f /usr/local/sbin/flannel-watchdog.sh \
                                /etc/systemd/system/flannel-watchdog.service \
                                /etc/systemd/system/flannel-watchdog.timer \
                                /etc/default/flannel-watchdog && \
                      sudo systemctl daemon-reload'
```

Repeat on `hostinger2`.

## Limits

- The watchdog **doesn't fix the root cause** of `flannel.1` vanishing
  (Tailscale interaction, kernel, k3s) — it just makes the symptom
  invisible. Tracked on
  [#127, section 4](https://github.com/danify-cz/danify-app/issues/127).
- During the `k3s-agent` restart (~10–15 s) every pod on the node is
  briefly unreachable from outside the node. This is the same trade-off
  as the manual restart we'd do anyway.
- The watchdog does **not** monitor CoreDNS, postgres or any service —
  it's strictly about the flannel data plane.
