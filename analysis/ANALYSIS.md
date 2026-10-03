# Kp-only baseline: forecasting storm likelihood from Kp's own history

A separate project from the collector, sharing only the database it writes. This one asks a narrower question than "forecast the solar wind": **can Kp's own time series tell us how likely a geomagnetic storm is, without looking at solar wind data at all?** See the project conversation (or ask) for why this is the deliberately simpler starting point, with solar wind/Bz as a planned later extension, not a requirement.

## Why a separate project, and why Kp-only first

- **Target alignment.** "Storm likelihood" is defined in terms of Kp (NOAA's G-scale: G1 = Kp 5, up to G5 = Kp 9). Modeling Kp directly means the model's output is already in the right units — no extra, error-compounding translation step from a solar-wind forecast through an uncertain coupling function.
- **Tractable cadence.** Kp is 3-hourly. A classical time series toolkit (persistence, ETS, ARIMA) fits it well, and decades of history are freely available (see below), unlike the collector's own few weeks of live data.
- **It's reusable.** This project reads the collector's SQLite database (the one thing the two projects share) but is otherwise independent — its own `renv`, own packages (the `fable`/`tsibble`/`feasts` modern forecasting ecosystem), so it can carry heavier dependencies without affecting the lean collector deployed on the VPS.
- **What's deliberately NOT here yet:** solar wind/Bz as predictors, and a 27-day seasonal (solar-rotation) term. Both slot into the same model-fitting call as one more formula term — see the comment at the bottom of `R/model.R` for exactly how — so adding either later doesn't require restructuring this baseline.

## Data

| Source | Role | Coverage |
|---|---|---|
| [GFZ Potsdam](https://kp.gfz.de/en/) Kp API | Training history | 1932–present, `status=def` ("definitive", won't be revised later) |
| The collector's `kp` table (`../data/spacewx.sqlite`) | Live continuation | Since the collector was deployed |
| GFZ API again, `status` unset | A short bridge | Only the gap between GFZ's definitive cutoff (~5 weeks behind "now") and the collector's start, which would otherwise be a 2-week hole nothing else covers |

Kp is a **measurement**, not something computed from solar wind — see the project discussion on why there's no deterministic formula from (speed, Bz) to Kp. GFZ is the index's official source; NOAA's own "estimated Kp" (what the collector stores) is a real-time approximation of the same thing from a subset of the same global magnetometer network.

Only the last `train_years + backtest_years` (default 25) years are actually loaded into the model, even though the cache holds the full archive back to 1932 — see the comment on `train_years` in `R/config.R` for why (older eras aren't necessarily representative, and fitting+backtesting on a quarter-million points is needlessly slow for no real benefit).

## Pipeline

```
fetch_historical_kp.R  →  data/kp_history.csv  (cached, re-run occasionally to pick up newly "def" months)
                                    │
fit_baseline.R  ──────────────────┴──→  data/baseline_results.rds
   │  loads history + bridge + collector's live data
   │  fits NAIVE / ETS / ARIMA on a training window
   │  backtests across rolling origins in a held-out test period
   ▼
kp-baseline-report.qmd  →  kp-baseline-report.html   (reads the .rds, renders the results)
```

Run it:
```sh
Rscript -e 'renv::restore()'     # once
Rscript fetch_historical_kp.R    # once, then occasionally to refresh
Rscript fit_baseline.R           # fits + backtests; takes a while (see below)
quarto render kp-baseline-report.qmd
```

## Models and evaluation

Three candidates, in increasing complexity — see `R/model.R` for the reasoning behind each:
1. **NAIVE** ("same as now") — the baseline everything else must beat. Storms are rare, so raw accuracy is misleading; report *skill against this*, not accuracy.
2. **ETS** — short-memory exponential smoothing.
3. **ARIMA** — can capture structure ETS can't (e.g. asymmetric decay after a spike).

Two things are reported, because they answer different questions:
- **RMSE skill** (`R/evaluate.R::rmse_skill()`) — how much better the continuous Kp forecast is than persistence.
- **Brier skill** (`R/evaluate.R::brier_skill()`) — how much better the *storm probability* forecast (P(Kp ≥ 5), from the model's own predictive distribution, not just its point forecast) is than climatology (the storm's plain base rate). This is the number that actually answers "how good is this at the thing we care about".

Both come from the same **rolling-origin backtest**: refit all three models fresh at each of several origins spread across a held-out test period (default: last 5 years, stepped roughly monthly), forecast `horizon_steps` ahead (default 4 = 12 hours) from each, and score against what actually happened. A single train/test split would let one lucky or unlucky window decide the result; this doesn't.

## A known cost: this is slow to run

Refitting ETS and ARIMA from scratch at every backtest origin, on a `train_years`-sized window, is the honest way to evaluate a time series model (Hyndman & Athanasopoulos's standard rolling-origin method) — but it's also the expensive part. If `fit_baseline.R` is taking too long for comfortable iteration, the knobs to turn are in `R/config.R`:
- `backtest_step` — coarser stepping (fewer origins) is the biggest lever.
- `train_years` — a shorter training window per fold fits faster.
- `backtest_years` — a shorter test period means fewer origins total.

Reduce these for quick iteration while developing; widen them again for the version you actually report results from.

## What this baseline can and can't tell you

- It will likely do well at **persistence and decay** — "an elevated Kp will probably still be elevated in 12 hours" is a strong, learnable pattern.
- It cannot see **storm onset** before Kp itself starts moving. The trigger (a CME or corotating stream) is physically upstream and invisible to a Kp-only model — that's precisely the gap the solar-wind extension (not built here) is meant to close, and precisely why the project's live collector exists at all.
