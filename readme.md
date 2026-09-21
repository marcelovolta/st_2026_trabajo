# Real-time space weather: data collection and forecasting

A time series project on **space weather**. The goal is to collect NOAA's live solar wind and geomagnetic measurements continuously, build a history that NOAA does not keep, and use it to forecast solar wind conditions and geomagnetic activity in near real time.

## Background

The Sun emits a constant stream of charged particles (the solar wind) carrying a magnetic field. Spacecraft stationed about 1.5 million km sunward of Earth, at the Sun-Earth Lagrange point L1, measure it 30 to 60 minutes before it reaches us. Fast wind and a southward-pointing magnetic field (negative Bz) can trigger geomagnetic storms that disturb satellites, GPS, radio and power grids.

That lead time is what makes forecasting possible: what the spacecraft sees now will reach Earth within the hour.

For the full explanation (the spacecraft, what every variable means, the data structure and how much data exists), see **[docs/space-weather-data.md](docs/space-weather-data.md)**.

## Data

Public, free, no API key. All from the NOAA Space Weather Prediction Center:

| Feed | Content | Cadence |
|---|---|---|
| Solar wind plasma | speed, density, temperature | 1 per minute |
| Interplanetary magnetic field | Bt, Bx, By, Bz | 1 per minute |
| Planetary Kp index | geomagnetic activity, 0-9 | 1 per 3 hours |

NOAA publishes only the last ~24 hours of the minute-level feeds, so a long time series exists only if someone collects it continuously. That is the job of this repository's collector.

## Project plan

The work is split into two independent projects that share only the database schema:

1. **Collector** (this repository, working): downloads the feeds every 5 minutes and stores them in SQLite. It is designed to run unattended on a small server, survive outages and restarts, and never store duplicates.
2. **Analysis and forecasting** (separate project, not started): reads the collected data to
   - forecast solar wind speed a few minutes ahead, evaluated against a naive "same as now" baseline;
   - forecast the Kp index using wind speed and Bz measured at L1 as predictors;
   - publish forecasts as they are made and score them afterwards, so results are honestly out-of-sample.

Data will also be shared with others, most likely as periodic Parquet or CSV snapshots.

## Quick start

Requires R 4.4.3 (the packages are pinned with `renv`).

```sh
Rscript -e 'renv::restore()'   # once: install the exact package versions
Rscript collect.R              # one collection cycle; the first run loads ~24 h of history
Rscript check.R                # health report: row counts, freshness, recent runs, gaps
```

Data is stored in `data/spacewx.sqlite` (not tracked by git). To run it automatically every 5 minutes on your Mac, or to deploy it to a VPS, follow **[COLLECTOR.md](COLLECTOR.md)**.

## Repository layout

```
collect.R            entry point: one collection cycle
check.R              health report for the collected data
R/                   config (feeds and settings), database, download logic, helpers
deploy/              systemd service + timer (VPS) and launchd job (macOS)
docs/                background on the science and the data
COLLECTOR.md         how to run, deploy and monitor the collector
renv.lock            pinned R package versions
```

## Status

- Collector: implemented and tested on macOS against the live NOAA feeds. Not yet deployed on a VPS.
- Analysis and forecasting: not started.

## Data source and license

The measurements come from NOAA SWPC, which publishes them as US government public data. The spacecraft involved are SOLAR-1 (NOAA), IMAP and ACE (NASA). Real-time data is preliminary: it is meant for operations, not final science.
