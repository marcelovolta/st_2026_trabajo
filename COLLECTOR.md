# Space weather collector

Downloads NOAA SWPC real-time feeds (solar wind, magnetic field, Kp index) every 5 minutes and stores them in a SQLite database. This project **only collects**; analysis and forecasting belong in a separate project that reads the database.

> New to the topic? Read [docs/space-weather-data.md](docs/space-weather-data.md) first: it explains the science, the spacecraft, what each column means and how much data exists.

## How it works

```
NOAA SWPC JSON feeds ──► collect.R (one cycle, then exits) ──► data/spacewx.sqlite
                              ▲
        scheduler runs it every 5 min (systemd timer on the VPS, launchd on the Mac)
```

| File | Purpose |
|---|---|
| `collect.R` | Entry point. One cycle: fetch every feed, store new rows, exit 0 (ok) or 1 (a feed failed). |
| `R/config.R` | The feeds to collect and all settings. Add a feed here. |
| `R/db.R` | SQLite schema, connection, safe insert (`ON CONFLICT`). |
| `R/ingest.R` | Download, validate, convert types, store one feed. |
| `R/utils.R` | UTC timestamps, logging, healthcheck ping. |
| `check.R` | Health report: row counts, freshness, recent runs, gaps. |
| `deploy/` | systemd unit + timer (VPS), launchd job (Mac). |
| `.env.example` | Optional settings (DB path, healthcheck URL). |

Tables: `wind` (speed, density, temperature), `mag` (Bt, Bx, By, Bz), `kp` (3-hourly geomagnetic index), `ingest_log` (one row per feed per run). All times are **UTC**. Wind and mag have several spacecraft reporting in parallel (`source` = SOLAR1, ACE, IMAP); the analysis project decides which one to use (`active = 1` marks NOAA's operational source).

## Run it locally (Mac mini)

```sh
Rscript -e 'renv::restore()'   # once: installs the exact package versions
Rscript collect.R              # one cycle; first run loads ~24 h of history
Rscript check.R                # is it healthy?
```

To run it automatically every 5 minutes on the Mac:

```sh
mkdir -p logs
cp deploy/launchd/local.spacewx-collector.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.spacewx-collector.plist
tail -f logs/collector.log
# to stop: launchctl bootout gui/$(id -u)/local.spacewx-collector
```

The Mac must not sleep: System Settings → Energy → "Prevent automatic sleeping when the display is off". A LaunchAgent only runs while you are logged in. That is fine for testing; the VPS is the real deployment.

## Deploy to a VPS (Ubuntu/Debian)

> Deployed and verified on a DigitalOcean droplet (Ubuntu 24.04, R 4.4.3) on 2026-09-22. The steps below are what was actually run.

**1. Server.** Any small Linux VPS (1 vCPU / 1 GB RAM is plenty). Log in over SSH.

**2. System packages and R 4.4.3** (same version as `renv.lock`):
```sh
sudo apt update && sudo apt install -y git curl sqlite3 libcurl4-openssl-dev libssl-dev
curl -Ls https://github.com/r-lib/rig/releases/download/latest/rig-linux-$(arch)-latest.tar.gz | sudo tar xz -C /usr/local
sudo rig add 4.4.3
which Rscript        # if not /usr/local/bin/Rscript, edit ExecStart in the .service file
```

**3. Get the code onto the server.** Push this repo to a private GitHub repo and clone it, or copy it with `rsync -a --exclude data --exclude .git ./ user@server:/tmp/collector/`.

**4. Dedicated user and folders:**
```sh
sudo useradd --system --create-home --shell /usr/sbin/nologin spacewx
sudo mkdir -p /opt/spacewx-collector /var/lib/spacewx
sudo chown spacewx:spacewx /opt/spacewx-collector /var/lib/spacewx
sudo -u spacewx git clone <your-repo-url> /opt/spacewx-collector
```

**5. Install the packages** (the first `Rscript` in the folder bootstraps renv automatically):
```sh
cd /opt/spacewx-collector
sudo -u spacewx Rscript -e 'renv::restore()'
```

**6. Settings.** Keep the database outside the code folder:
```sh
sudo tee /etc/spacewx-collector.env >/dev/null <<'EOF'
SPACEWX_DB_PATH=/var/lib/spacewx/spacewx.sqlite
# SPACEWX_HEALTHCHECK_URL=https://hc-ping.com/your-uuid-here
EOF
```

**7. Install the scheduler and test one run by hand:**
```sh
sudo cp deploy/systemd/spacewx-collector.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start spacewx-collector.service       # one cycle now
journalctl -u spacewx-collector -n 20 --no-pager     # expect three "ok" lines
sudo systemctl enable --now spacewx-collector.timer  # every 5 min, and at every boot
systemctl list-timers spacewx-collector.timer        # shows the next run
```

**8. Check on it any time:**
```sh
cd /opt/spacewx-collector && sudo -u spacewx env SPACEWX_DB_PATH=/var/lib/spacewx/spacewx.sqlite Rscript check.R
```

**9. Firewall.** A fresh droplet accepts any connection by default. Allow only SSH in:
```sh
ufw allow OpenSSH
ufw --force enable
ufw status
```
Always allow SSH *before* enabling, or you lock yourself out.

**10. Daily backups.** `deploy/backup.sh` takes a consistent snapshot (safe while the collector writes), gzips it, and prunes anything older than 14 days. Install it to run once a day as the `spacewx` user:
```sh
chmod +x /opt/spacewx-collector/deploy/backup.sh
cat <<'EOF' > /etc/cron.d/spacewx-backup
0 3 * * * spacewx /opt/spacewx-collector/deploy/backup.sh >> /var/log/spacewx-backup.log 2>&1
EOF
touch /var/log/spacewx-backup.log && chown spacewx:spacewx /var/log/spacewx-backup.log
sudo -u spacewx /opt/spacewx-collector/deploy/backup.sh   # test it once by hand
```
Backups land in `/var/lib/spacewx/backups/`. This protects against corruption or a mistake on the server, **not** against losing the server itself — periodically copy the folder off-box (e.g. `scp` it to your Mac).

**11. Uptime alert.** Create a free check at [healthchecks.io](https://healthchecks.io) (no account needed to try it, but sign up to manage it later) named e.g. "spacewx collector", with a period of 10 minutes and a grace time of 5 minutes. Copy its ping URL (`https://hc-ping.com/<uuid>`) into the settings file:
```sh
cat <<'EOF' >> /etc/spacewx-collector.env
SPACEWX_HEALTHCHECK_URL=https://hc-ping.com/<uuid>
EOF
systemctl start spacewx-collector.service   # trigger one run so it pings right away
```
If the collector stops pinging for the grace period, healthchecks.io emails you.

## What happens when something fails

| Situation | Behavior |
|---|---|
| VPS or Mac is off / rebooted | Timer resumes at boot (`Persistent=true`). Each download holds the last ~24 h, so outages **under 24 h leave no gap**. |
| Outage longer than 24 h | The missing period is a real gap. `check.R` lists it; analysis must treat it as missing data. |
| NOAA is slow or returns a 5xx error | Retried 3 times with growing waits; if still failing, that feed is logged as `error`, the others still run, exit code 1. |
| NOAA changes a feed format | The run fails loudly (`feed is missing expected fields`) instead of storing garbage. This has already happened once: the old `products/solar-wind/*.json` URLs now return 404. |
| Two runs overlap or repeat | Harmless: rows are keyed by (time, source) and duplicates are skipped. systemd never runs the same service twice at once. |
| Process is killed mid-write | Inserts are transactions and SQLite runs in WAL mode; the file is not corrupted. |
| Machine silently dead | Set `SPACEWX_HEALTHCHECK_URL` (free at healthchecks.io). No ping for ~10 min ⇒ you get an email. |

Not covered yet: NOAA serving *stale* data with HTTP 200 (rows_new stays 0 run after run). It is visible in `check.R` and `ingest_log`, but nothing alerts on it automatically.

## Backups and sharing

SQLite is a single file, but do not copy it with `cp` while the collector runs. Use a consistent snapshot:
```sh
sqlite3 /var/lib/spacewx/spacewx.sqlite ".backup '/var/backups/spacewx-$(date +%F).sqlite'"
```
Put that in a daily cron job and copy the result off the server. To share data with others, publish periodic snapshots (Parquet or CSV exports) rather than giving access to the live file. NOAA SWPC data is US-government public data.

## Adding a feed

1. Add an entry to `FEEDS` in `R/config.R` (URL, column mapping, types, key).
2. Add a matching `CREATE TABLE IF NOT EXISTS` to `SCHEMA` in `R/db.R`.
3. Nothing else: `collect.R` loops over `FEEDS`.

To store extra fields from an existing feed (e.g. the GSE velocity components), add them to both places. Existing tables are not altered automatically: add the column with `ALTER TABLE ... ADD COLUMN`, or start a new database.
