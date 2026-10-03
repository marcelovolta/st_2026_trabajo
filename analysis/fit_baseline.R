# ---- Fit and evaluate the Kp-only baseline ---------------------------------------
# Naive persistence, ETS and ARIMA, scored against each other with a rolling-
# origin backtest: RMSE skill (continuous value) and Brier skill (storm
# likelihood). Run fetch_historical_kp.R first.
#
#   Rscript fit_baseline.R
#
# Saves fitted models + backtest results to data/ (gitignored) so the report
# notebook (kp-baseline-report.qmd) can read them without re-running this.

if (!file.exists("R/config.R")) stop("Run this script from the analysis/ folder.")
for (f in list.files("R", pattern = "\\.R$", full.names = TRUE)) source(f)

cfg <- load_config()

cat("Loading data...\n")
ts_full <- load_combined_kp_series(cfg)

# Keep only the recent window we'll actually train and evaluate on (see
# cfg$train_years for why) -- everything older stays in the cache on disk for
# if/when that choice is revisited, it just isn't loaded into the model.
window_start <- max(ts_full$time) - (cfg$train_years + cfg$backtest_years) * 365 * 86400
ts <- dplyr::filter(ts_full, time >= window_start)
cat(sprintf("Series: %d points, %s to %s (%d missing after gap-filling)\n",
           nrow(ts), format(min(ts$time)), format(max(ts$time)), sum(is.na(ts$kp))))

split <- split_train_test(ts, cfg$backtest_years)
cat(sprintf("Train: up to %s (%d points). Test: after that (%d points).\n",
           format(split$cutoff), nrow(split$train), sum(split$full$time > split$cutoff)))

cat("Fitting models on the training period...\n")
fit <- fit_kp_models(split$train)
print(fabletools::glance(fit))

cat("Backtesting across rolling origins in the test period (this takes a bit)...\n")
scored <- backtest_kp(split$full, split$cutoff, cfg$horizon_steps, cfg$backtest_step,
                      cfg$train_years, cfg$storm_threshold)

cat("\n== RMSE skill vs. naive persistence ==\n")
print(rmse_skill(scored))

cat("\n== Storm likelihood (Kp >=", cfg$storm_threshold, ") skill vs. climatology ==\n")
print(brier_skill(scored, split$train, cfg$storm_threshold))

cat("Fitting a separate model on the most recent data, for live forecasting...\n")
# `fit` above is deliberately held back at the backtest cutoff -- it has never
# seen the test period, which is what makes the backtest honest. A live
# forecast needs the OPPOSITE: everything available, right up to now.
live_window <- dplyr::filter(ts, time > max(ts$time) - cfg$train_years * 365 * 86400)
fit_live <- fit_kp_models(live_window)

dir.create("data", showWarnings = FALSE)
saveRDS(list(ts = ts, split = split, fit = fit, fit_live = fit_live, scored = scored, cfg = cfg),
       "data/baseline_results.rds")
cat("\nSaved to data/baseline_results.rds\n")
