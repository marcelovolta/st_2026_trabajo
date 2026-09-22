# VPS deployment log

A record of how the collector was actually deployed to a production server, on **2026-09-22**: what Marcelo did, what Claude did, and the exact commands and configuration used. For the general, repeatable checklist, see [`COLLECTOR.md`](../COLLECTOR.md#deploy-to-a-vps-ubuntudebian) — this document is the narrative of one specific run through it.

> **A note on redaction.** This repository is public, so the server's IP address and the healthchecks.io ping URL are replaced below with `<VPS_IP>` and `<HEALTHCHECK_URL>`. Publishing a live server's address in a public, permanent document is unnecessary exposure, even with key-only SSH. The real values are not stored anywhere in this repo; they are kept in Claude Code's local project memory on Marcelo's machine and in the DigitalOcean/healthchecks.io dashboards.

## Outcome

The collector has been running unattended on a DigitalOcean droplet since 2026-09-22, polling NOAA every 5 minutes, with a firewall, daily backups and an uptime alert. It ran in parallel with the Mac mini collector for a day as a cross-check before the Mac job was retired.

## 1. Provisioning (Marcelo)

- Recommended plan: a small Ubuntu 24.04 droplet (Claude suggested Hetzner CX22; Marcelo used **DigitalOcean** instead — either works, the deploy steps are provider-agnostic once SSH access exists).
- Generated an SSH key pair locally, non-interactively (the interactive prompt doesn't work through Claude Code's `!` command relay):
  ```sh
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keygen -t ed25519 -C "spacewx-vps" -f ~/.ssh/id_ed25519 -N ""
  ```
- Created the droplet in the DigitalOcean console: Ubuntu 24.04, smallest plan (`s-1vcpu-1gb`), with the new public key attached so root login is key-only from the start.
- Shared the droplet's public IP.

## 2. First connection (Claude + Marcelo)

The droplet's host key had to be trusted before an unattended SSH session would work:
```sh
ssh-keyscan -H <VPS_IP> >> ~/.ssh/known_hosts
ssh -o BatchMode=yes root@<VPS_IP> 'echo connected && whoami && cat /etc/os-release | head -3'
```
Confirmed: `Ubuntu 24.04.4 LTS`, logged in as `root`, key-based auth working. From this point, since the same SSH key was usable directly from Claude's own shell (same Mac), Claude ran the remaining steps directly over SSH rather than relaying commands for Marcelo to paste — confirmed with Marcelo first.

## 3. System packages and R (Claude, via SSH)

```sh
apt update && apt install -y git curl sqlite3 libcurl4-openssl-dev libssl-dev
```

R 4.4.3 — matching `renv.lock` — installed via [`rig`](https://github.com/r-lib/rig):
```sh
curl -Ls https://github.com/r-lib/rig/releases/download/latest/rig-linux-x86_64-latest.tar.gz | tar xz -C /usr/local
rig add 4.4.3
```
Verified: `which Rscript` → `/usr/local/bin/Rscript` (matches `ExecStart` in the systemd service, so no edit needed there).

## 4. Code, dedicated user, packages (Claude, via SSH)

The repository is public, so no deploy key was needed. A test clone to `/tmp` confirmed access, then was deleted; the real clone was made as an unprivileged, login-disabled system user:
```sh
useradd --system --create-home --shell /usr/sbin/nologin spacewx
mkdir -p /opt/spacewx-collector /var/lib/spacewx
chown spacewx:spacewx /opt/spacewx-collector /var/lib/spacewx
sudo -u spacewx git clone https://github.com/marcelovolta/st_2026_trabajo /opt/spacewx-collector
```

Packages restored from the lockfile (all installed from binary, no compilation needed):
```sh
cd /opt/spacewx-collector
sudo -u spacewx Rscript -e 'renv::restore()'
```
`renv::status()` afterward: *"No issues found — the project is in a consistent state."*

## 5. Settings and scheduler (Claude, via SSH)

`/etc/spacewx-collector.env` (kept outside the git-managed code folder, as it holds the runtime path and, later, the healthcheck URL):
```sh
SPACEWX_DB_PATH=/var/lib/spacewx/spacewx.sqlite
```

Systemd units copied from the repo (`deploy/systemd/spacewx-collector.{service,timer}` — see those files for full content) and enabled:
```sh
cp /opt/spacewx-collector/deploy/systemd/spacewx-collector.service /etc/systemd/system/
cp /opt/spacewx-collector/deploy/systemd/spacewx-collector.timer /etc/systemd/system/
systemctl daemon-reload
systemctl start spacewx-collector.service   # one cycle, run by hand first
```
First-run result, confirmed via `journalctl -u spacewx-collector`:
```
wind ok: 1660 rows fetched, 1660 new, newest 2026-09-22T18:47:00
mag  ok: 2284 rows fetched, 2284 new, newest 2026-09-22T18:47:00
kp   ok: 62 rows fetched, 62 new, newest 2026-09-22T15:00:00
```
Then the recurring timer:
```sh
systemctl enable --now spacewx-collector.timer
```

## 6. Verification (Claude, via SSH)

```sh
sudo -u spacewx env SPACEWX_DB_PATH=/var/lib/spacewx/spacewx.sqlite Rscript /opt/spacewx-collector/check.R
```
This surfaced two things worth recording, neither a deployment problem:
- Several gaps (up to 94 minutes) inside the very first ~24 h window NOAA served — pre-existing, since the VPS had no prior history to have filled them; the 5-minute timer prevents new ones going forward.
- NOAA's `active` (primary) source flag switched between `ACE` and `SOLAR1` partway through that same window — a NOAA-side event, not a collector issue. Useful context for the analysis project, since the `source`/`active` columns need to be handled explicitly.

## 7. Hardening: firewall, backups, uptime alert (Claude, via SSH, and Marcelo for the alert)

Added to the repo first (commit `a706224`), then pulled onto the server, so the deployed state matches what's documented in `COLLECTOR.md`:
```sh
git pull   # on the VPS, as the spacewx user
```

**Firewall.** SSH allowed *before* enabling, to avoid a lockout:
```sh
ufw allow OpenSSH
ufw --force enable
```
Verified the existing SSH session still worked afterward. Result: only port 22 open to the internet.

**Backups.** [`deploy/backup.sh`](../deploy/backup.sh) takes a consistent SQLite snapshot (`sqlite3 .backup`, safe while the collector writes concurrently), gzips it, and prunes anything older than 14 days.
```sh
chmod +x /opt/spacewx-collector/deploy/backup.sh
cat <<'EOF' > /etc/cron.d/spacewx-backup
0 3 * * * spacewx /opt/spacewx-collector/deploy/backup.sh >> /var/log/spacewx-backup.log 2>&1
EOF
touch /var/log/spacewx-backup.log && chown spacewx:spacewx /var/log/spacewx-backup.log
sudo -u spacewx /opt/spacewx-collector/deploy/backup.sh   # tested by hand, twice
```
Result: `/var/lib/spacewx/backups/spacewx-<timestamp>.sqlite.gz`, ~68 KB at first run. **Not yet done:** copying backups off the server (they currently protect against corruption/mistakes on the box, not against losing the box itself).

**Uptime alert.** Marcelo created a free check at [healthchecks.io](https://healthchecks.io) named "spacewx collector", using a **Simple** schedule (Period 10 min / Grace 5 min — chosen over a Cron schedule because the timer's `RandomizedDelaySec=20` makes exact-time cron matching noisy) and shared the ping URL. Claude added it to the settings file and triggered one run to confirm the first ping:
```sh
cat <<'EOF' >> /etc/spacewx-collector.env
SPACEWX_HEALTHCHECK_URL=<HEALTHCHECK_URL>
EOF
systemctl start spacewx-collector.service
```
Confirmed via `journalctl`: all three feeds `ok`, no `WARN healthcheck ping failed` line, meaning the ping reached healthchecks.io.

## Final state

| Aspect | Value |
|---|---|
| Provider | DigitalOcean, `s-1vcpu-1gb`, Ubuntu 24.04.4 LTS |
| Access | SSH, key-only (`PasswordAuthentication no`), `root` |
| Code | `/opt/spacewx-collector`, cloned and run as the unprivileged `spacewx` user |
| Database | `/var/lib/spacewx/spacewx.sqlite` |
| Schedule | systemd timer, every 5 minutes, `Persistent=true` (catches up after downtime) |
| Firewall | UFW active, inbound limited to SSH |
| Backups | Daily at 03:00 UTC, gzipped, 14-day retention, local to the server only |
| Monitoring | healthchecks.io, Simple schedule (10 min period / 5 min grace) |

## Open items

- Copy backups off the server periodically (no destination decided yet).
- `PermitRootLogin yes` is DigitalOcean's default; acceptable for a class project given key-only auth, but a non-root sudo user would be tighter if this ever moves beyond coursework.
- Retire the Mac mini's launchd job once the VPS has proven itself over a full day (see [`COLLECTOR.md`](../COLLECTOR.md#run-it-locally-mac-mini)).
