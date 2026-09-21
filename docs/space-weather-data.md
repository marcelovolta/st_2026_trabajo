# Space weather data: what we collect and why

This document explains the science behind the project, where the data comes from, what every number means, how the collector stores it, and how much data exists at any moment. It assumes no background in space physics. For the operational side (running and deploying the collector) see [`COLLECTOR.md`](../COLLECTOR.md).

*Facts about spacecraft and NOAA services were checked against the sources listed at the end on 2026-09-21. Numbers marked "observed" were measured from the live feeds on that date. Treat both as a snapshot: the space weather infrastructure is in the middle of a transition (see [section 8](#8-caveats-and-known-limitations)).*

---

## 1. What this project is about

The Sun continuously emits a stream of charged particles, the **solar wind**, and carries a magnetic field with it. Most of the time this is harmless. Occasionally, a burst of fast plasma or a strongly oriented magnetic field hits Earth and triggers a **geomagnetic storm**. Storms cause auroras, but they can also disturb satellites, GPS accuracy, radio communication and power grids.

The **solar wind is measured by spacecraft parked about 1.5 million km sunward of Earth**. Because the wind takes roughly 30 to 60 minutes to travel from there to Earth, those measurements are an early warning.

The project has two parts:

1. **Collect** (this repository): download NOAA's real-time measurements continuously and build a time series that NOAA itself does not keep (NOAA publishes only the last ~24 hours).
2. **Analyze and forecast** (a separate project): use that history to forecast solar wind conditions a few minutes ahead, and to forecast geomagnetic activity (the Kp index) that will arrive at Earth about an hour later.

## 2. Space weather in five minutes

```
   Sun                                         L1                       Earth
    ☀  ~~~ solar wind (300-800+ km/s) ~~~►    🛰   ~~~ 30-60 min ~~~►     🌍
                                             ~1.5 million km
                                       (about 1% of the Sun-Earth distance)
```

- **Solar wind:** a continuous flow of mostly protons and electrons. Typical speed is 300 to 500 km/s. High-speed streams from coronal holes reach 600 to 800 km/s. Very fast events exceed 1,000 km/s.
- **Interplanetary magnetic field (IMF):** the Sun's magnetic field, dragged along by the wind. Its strength is usually a few nanoteslas (nT).
- **Coronal mass ejections (CMEs):** huge clouds of plasma thrown out by the Sun. They arrive at L1 as sudden jumps in speed, density and field strength. They are the main cause of strong storms.
- **Solar flares** are a different phenomenon (bursts of X-rays and radio emission, measured by other satellites). They are *not* part of this dataset.
- **Geomagnetic storm:** what happens when the solar wind couples to Earth's magnetic field. The coupling is strongest when the IMF points **south** (negative Bz, explained in section 5), the speed is high, and the condition lasts for hours.
- **Kp index:** the standard 0-9 scale for how disturbed Earth's magnetic field is. NOAA turns it into storm levels: Kp 5 = G1 (minor) up to Kp 9 = G5 (extreme).

### Why a spacecraft at L1?

L1 is the Sun-Earth **Lagrange point 1**, a place where the gravity of the Sun and Earth balance so that a spacecraft can stay on the Sun-Earth line with little fuel. From there it sees the solar wind before Earth does.

The warning time depends on the wind speed:

| Wind speed | Travel time over 1.5 million km |
|---|---|
| 400 km/s (typical) | about 62 minutes |
| 600 km/s | about 42 minutes |
| 800 km/s | about 31 minutes |

That lead time is what makes forecasting possible: what a spacecraft sees at L1 now will reach Earth within the hour.

## 3. The spacecraft behind the data

All of them orbit around L1. The NOAA Space Weather Prediction Center (SWPC) receives their data, processes it, and republishes it as public JSON files. Our collector reads those files. It does not talk to any spacecraft.

| Spacecraft | Operator | Role in this dataset | `source` value |
|---|---|---|---|
| **SOLAR-1** (formerly SWFO-L1) | NOAA | **Primary source.** Launched 2025-09-24; arrived at L1 on 2026-01-23; fully operational since 2026-06-10. Carries a solar wind plasma sensor (SWiPS), a magnetometer and a coronagraph (CCOR-2) for imaging CMEs. Built to replace ACE and DSCOVR. | `SOLAR1` |
| **IMAP** (Interstellar Mapping and Acceleration Probe) | NASA | Launched 2025-09-24 on the same rocket as SOLAR-1. Its main mission is science (mapping the boundary of the heliosphere), but it also sends a real-time stream called **I-ALiRT** with solar wind plasma (instrument SWAPI) and magnetic field. Coverage is not yet continuous. | `IMAP` |
| **ACE** (Advanced Composition Explorer) | NASA | Launched 1997-08-25; feeds NOAA's real-time solar wind since February 1998. Now a **backup** with the plasma instrument SWEPAM and a magnetometer. Still running after ~29 years. | `ACE` |
| **DSCOVR** | NOAA/NASA/USAF | Real-time source from July 2016 until mid-2026. NOAA **stopped ingesting DSCOVR data** on 2026-06-30. It does **not** appear in our data. | (none) |

The three sources in the feed measure the **same solar wind at nearly the same place**, so they should agree closely. That gives redundancy, and it lets you check one against another.

## 4. From spacecraft to our database

```
Spacecraft at L1
   │  radio downlink to ground stations
   ▼
NOAA SWPC processing (quality checks, formatting)
   │  publishes JSON files, refreshed about every minute
   ▼
https://services.swpc.noaa.gov/...        (public, no key, no login)
   │  collect.R downloads every 5 minutes
   ▼
SQLite database (data/spacewx.sqlite)  ──►  analysis project, shared exports
```

The collector downloads three feeds:

| Feed | URL | What it contains | Cadence | Window in each download |
|---|---|---|---|---|
| **wind** | `/json/rtsw/rtsw_wind_1m.json` | Solar wind plasma | 1 observation per minute per source | last ~24 hours |
| **mag** | `/json/rtsw/rtsw_mag_1m.json` | Interplanetary magnetic field | 1 observation per minute per source | last ~24 hours |
| **kp** | `/products/noaa-planetary-k-index.json` | Estimated planetary Kp | 1 value per 3 hours | last ~7 days |

(All URLs are under `https://services.swpc.noaa.gov`.)

Each download **repeats** the previous 24 hours. That overlap is deliberate: if the collector is offline for a few hours, the next successful download fills the gap, and duplicates are discarded automatically. Outages longer than 24 hours are the only way to lose data permanently.

## 5. What the numbers mean

### Solar wind plasma (`wind` table)

| Column | Unit | Meaning | Rule of thumb |
|---|---|---|---|
| `proton_speed` | km/s | Bulk speed of the wind. The single most important plasma variable. | 300-450 calm; > 500 fast stream; > 800 strong CME |
| `proton_density` | particles/cm³ | How crowded the wind is. | ~5 typical; sharp jumps mark shocks |
| `proton_temperature` | Kelvin | Thermal motion of the protons. | 10⁴ to 10⁶ K; usually higher in fast wind |

### Interplanetary magnetic field (`mag` table)

| Column | Unit | Meaning |
|---|---|---|
| `bt` | nT | Total strength of the field. ~5 nT is typical; > 15 nT is strong. |
| `bx_gsm`, `by_gsm` | nT | Field components along the Sun-Earth line (x) and across it (y). |
| `bz_gsm` | nT | **North-south component. The key variable for storms.** |

**Why Bz matters.** Earth's magnetic field at the boundary facing the Sun points north. When the incoming field points **south** (negative Bz), the two fields connect ("magnetic reconnection") and solar wind energy pours into Earth's magnetosphere. A sustained Bz below about -10 nT for several hours, combined with high speed, is the classic recipe for a strong storm. Positive Bz mostly bounces off.

**GSM coordinates** (Geocentric Solar Magnetospheric): x points from Earth to the Sun, and z is chosen so that Earth's magnetic dipole axis lies in the x-z plane. The point is that "south" means south relative to Earth's own field. This is why we store the `_gsm` components.

### Geomagnetic activity (`kp` table)

| Column | Meaning |
|---|---|
| `time_tag` | **Start** of the 3-hour period (00, 03, 06 ... 21 UTC). |
| `kp` | Estimated planetary index, 0 to 9 in steps of one third (0, 0.33, 0.67, 1.0, 1.33, ...). ≥ 5 is a storm (G1); 9 is extreme (G5). |
| `a_running` | The linear "a" equivalent of the index (Kp is quasi-logarithmic; "a" is easier to average). |
| `station_count` | How many ground magnetometer stations went into the estimate (observed: 7-8). |

This Kp is **NOAA's real-time estimate** from a subset of ground magnetometer stations. The final, official Kp is produced later by a research institute and can differ slightly. For forecasting research the estimate is what you get in real time; for a final paper you may want the official series.

Kp is the natural **target** to predict, and wind speed plus Bz are the natural **predictors**. That is the whole logic of the project.

## 6. Data structure

### What NOAA sends, and what we keep

NOAA's feeds are JSON arrays with one object per observation. The wind records carry 31 fields and the magnetic field records 22. We keep only the scientifically relevant ones and drop the rest (alpha-particle measurements, velocity vectors, instrument status flags). One raw record, trimmed to the fields we keep:

```json
{ "time_tag": "2026-09-21T12:16:00", "source": "SOLAR1", "active": true,
  "proton_speed": 329.2, "proton_density": 1.63, "proton_temperature": 55250,
  "overall_quality": 0 }
```

### Our database (SQLite)

Four tables. **All timestamps are UTC**, in ISO-8601 text (`2026-09-21T12:16:00`), which sorts chronologically as plain text.

| Table | Primary key | Content | Written as |
|---|---|---|---|
| `wind` | `(time_tag, source)` | plasma observations | append-only: first value seen is kept |
| `mag` | `(time_tag, source)` | magnetic field observations | append-only |
| `kp` | `time_tag` | 3-hour Kp estimates | updated if NOAA revises a value |
| `ingest_log` | `id` | one row per feed per collector run: status, rows fetched, rows new, error message | append-only |

Example rows (real, from 2026-09-21):

```
wind: 2026-09-21T12:16:00  SOLAR1  active=1  speed=329.2  density=1.63  temp=55250  quality=0
mag : 2026-09-21T12:14:00  SOLAR1  active=1  bt=4.17  bx=2.79  by=-2.70  bz=1.46   quality=0
kp  : 2026-09-21T09:00:00  kp=0.67  a_running=3  station_count=8
```

Every observation table also has `ingested_at`: the UTC time **we** stored the row. It lets you audit outages and, importantly for forecasting, reconstruct *what was known at a given moment*.

### Things to know before using the data

- **Three sources per minute.** A given `time_tag` normally appears once per source, so `wind` holds about 2.7 rows per minute. Always filter or choose by `source`. A reasonable default is `active = 1` (currently SOLAR1), falling back to another source when it is missing. The `active` flag looks like NOAA's "primary source" marker (SOLAR-1 is primary and ACE is backup, per NOAA's announcement), but NOAA's documentation does not define the field precisely, so confirm it before relying on it.
- **Timestamps differ by source.** SOLAR1 and ACE report on whole minutes; IMAP uses odd seconds (e.g. `12:16:05`). To combine sources, round to the minute.
- **Missing values are `NULL`.** Observed: 2 of ~1,480 SOLAR1 wind rows had no plasma values. We do not fill or interpolate anything in the database.
- **Quality flag.** `overall_quality = 0` was the value on every row observed. Check whether non-zero values appear over time and exclude them if so.
- **Units and time** are as in section 5; nothing is converted.

## 7. How much data is there?

There are two different answers, because there are two places the data lives.

### (a) At NOAA, at any moment: about 24 hours

Each download of the wind feed contains roughly the **last 24 hours**. NOAA does not offer a longer history from these endpoints. Observed on 2026-09-21:

| Feed | Rows per download | Compressed download size |
|---|---|---|
| wind | ~3,900 | ~100 KB |
| mag | ~3,950 | ~155 KB |
| kp | ~60 (7 days) | < 1 KB |

Rows per source in the last ~26 hours of our test database:

| Source | wind rows | mag rows | Coverage of the period |
|---|---|---|---|
| SOLAR1 (primary) | 1,478 | 1,486 | ~99% of minutes |
| ACE | 1,353 | 1,356 | ~90%, a few gaps up to 6 min |
| IMAP | 1,246 | 1,249 | ~84%, includes one gap of about 4 hours |

### (b) In our database: grows from the day the collector starts

Once the collector is running, the database accumulates everything it has seen. The **usable time series is one observation per minute per variable**, about 1,440 per day from the primary source. Rough growth (estimated from a 26-hour test database, about 160 bytes per row including indexes):

| Collected for | Rows (wind + mag, all sources) | Approx. file size | Primary-source minutes |
|---|---|---|---|
| 1 day | ~7,900 | ~1.2 MB | ~1,440 |
| 1 week | ~55,000 | ~9 MB | ~10,000 |
| 1 month | ~235,000 | ~37 MB | ~43,000 |
| 1 year | ~2.9 million | ~450 MB | ~525,000 |

These are small volumes, so storage is not a constraint. **History is.** The real limit is *how long the collector has been running without gaps*, since there is no way to download last month's data from these endpoints after the fact. (Longer archives do exist elsewhere, for example NASA's OMNIWeb dataset going back decades, and could be used for model training. That is outside this collector.)

## 8. Caveats and known limitations

- **The infrastructure is changing.** In mid-2026 SOLAR-1 replaced DSCOVR as the primary source; ACE is the backup "until IMAP I-ALiRT achieves continuous coverage". Before that, the same feeds contained different sources. **A long time series will mix instruments** with slightly different calibrations. Keep the `source` column and check for level shifts around 2026-06.
- **Endpoint stability.** NOAA moved and retired products during this transition: the old `products/solar-wind/*.json` URLs return 404 today, and `swpc.noaa.gov` now redirects to `spaceweather.gov`. The collector validates the field names on every run and fails loudly if the format changes, rather than storing bad data.
- **Real-time data is preliminary.** It is intended for operations, not final science. Values may be revised, and calibration is basic.
- **The data is measured at L1, not at Earth.** Anything you predict at Earth must account for the travel time (section 2), which depends on speed.
- **Kp is an estimate** (section 5), and storms are rare. Most of the time Kp is below 4, so a forecaster that always predicts "quiet" looks accurate. Evaluate against a naive baseline and on storm events specifically.
- **Gaps.** The primary source itself has occasional missing minutes, and IMAP's coverage is incomplete. Analysis code must handle missing values explicitly.

## 9. Glossary

| Term | Meaning |
|---|---|
| **L1** | Sun-Earth Lagrange point 1, ~1.5 million km from Earth toward the Sun |
| **SWPC** | NOAA Space Weather Prediction Center |
| **IMF** | Interplanetary magnetic field |
| **nT** | Nanotesla; unit of magnetic field (Earth's surface field is ~50,000 nT) |
| **GSM** | Geocentric Solar Magnetospheric coordinates |
| **CME** | Coronal mass ejection |
| **Kp** | Planetary geomagnetic activity index, 0-9 |
| **G-scale** | NOAA storm levels G1 (Kp 5) to G5 (Kp 9) |
| **RTSW** | Real-Time Solar Wind (the name of NOAA's product) |
| **I-ALiRT** | IMAP Active Link for Real-Time data |

## Sources

- NOAA SWPC, [Solar wind data and display changes](https://swpc-drupal.woc.noaa.gov/news/solar-wind-data-and-display-changes) (2026-06-30): DSCOVR ingest stopped; SOLAR-1 primary; ACE backup.
- NOAA SWPC, [Real-time solar wind](https://www.spaceweather.gov/products/real-time-solar-wind): sources, dates, plotted quantities, Bz significance.
- Wikipedia, [SOLAR-1 (Space weather Observations at L1 to Advance Readiness - 1)](https://en.wikipedia.org/wiki/Space_weather_Observations_at_L1_to_Advance_Readiness_-_1): launch, arrival, instruments.
- NOAA, [SWFO-L1 heads to orbit](https://www.noaa.gov/news-release/noaas-swfo-l1-observatory-heads-to-orbit-for-groundbreaking-mission): launch on Falcon 9 with IMAP and Carruthers.
- NOAA SWPC, [NASA's IMAP Active Link for Real-Time data now available](https://www.spaceweather.gov/news/nasas-imap-active-link-real-time-data-now-available).
- NASA, [ACE mission](https://science.nasa.gov/mission/ace) and [eoPortal: ACE](https://www.eoportal.org/satellite-missions/ace): launch, instruments, L1 orbit.
- NOAA SWPC, [Planetary K-index](https://www.spaceweather.gov/products/planetary-k-index) and [The K-index (PDF)](https://www.swpc.noaa.gov/sites/default/files/images/u2/TheK-index.pdf): definition of Kp, estimated Kp, G-scale.
- Live feeds inspected 2026-09-21 for field names, cadence, row counts and coverage.
