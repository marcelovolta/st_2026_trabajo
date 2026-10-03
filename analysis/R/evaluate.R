# ---- Backtesting: does this beat the naive baseline? ----------------------------
# Rolling-origin evaluation: forecast from many points in time, not just one, so
# a single lucky (or unlucky) window doesn't decide the result. Follows the
# standard fable/fpp3 pattern: fit once on the training data, then re-apply
# those already-estimated coefficients at each later origin (`reestimate =
# FALSE`) rather than re-fitting from scratch hundreds of times -- this is what
# keeps a multi-year backtest fast enough to run on a laptop.

#' Split into a training period and a held-out test period of `test_years`.
split_train_test <- function(ts, test_years) {
  cutoff <- max(ts$time) - test_years * 365 * 86400
  list(train = dplyr::filter(ts, time <= cutoff), full = ts, cutoff = cutoff)
}

#' Forecast from many rolling origins across the test period and score them,
#' both as a point value (for RMSE skill) and as P(storm) (for Brier skill) in
#' one pass. Returns one row per (model, origin, horizon step).
#'
#' Refits all three models fresh at each origin, on a bounded `train_years`
#' window ending at that origin (not an ever-expanding one -- see
#' cfg$train_years in R/config.R for why). `step` sets how far apart the
#' origins are; keep it coarse (weeks/months, not days) or the number of
#' refits becomes impractical. A model that fails to fit for a given origin is
#' skipped for that origin rather than aborting the whole backtest -- ARIMA's
#' order search occasionally doesn't converge on a particular window, which
#' is a real, reportable limitation, not a bug to hide.
backtest_kp <- function(full_ts, cutoff, horizon, step, train_years, storm_threshold) {
  origins <- seq(cutoff, max(full_ts$time) - horizon * 3 * 3600, by = step * 3 * 3600)
  results <- vector("list", length(origins))

  for (i in seq_along(origins)) {
    origin <- origins[i]
    train_window <- dplyr::filter(full_ts, time > origin - train_years * 365 * 86400, time <= origin)
    fit <- tryCatch(fit_kp_models(train_window), error = function(e) NULL)
    if (is.null(fit)) next

    fc <- tryCatch(
      forecast_kp(fit, horizon) |> storm_probability(storm_threshold),
      error = function(e) NULL
    )
    if (is.null(fc)) next

    results[[i]] <- tibble::as_tibble(fc) |>
      dplyr::select(.model, time, kp_pred = .mean, p_storm) |>
      dplyr::left_join(dplyr::as_tibble(full_ts) |> dplyr::select(time, kp_actual = kp), by = "time") |>
      dplyr::mutate(origin = origin)

    if (i %% 10 == 0) cat(sprintf("  origin %d/%d (%s)\n", i, length(origins), format(origin)))
  }

  dplyr::bind_rows(results)
}

#' RMSE skill score: how much better than the naive baseline, as a fraction.
#' 0 = no better than naive; 1 = perfect; negative = worse than naive.
#' This is the number to report, not raw RMSE, since raw RMSE alone doesn't
#' say whether the model earned its complexity.
rmse_skill <- function(scored, baseline_model = "naive") {
  rmse_by_model <- scored |>
    dplyr::filter(!is.na(kp_actual)) |>
    dplyr::group_by(.model) |>
    dplyr::summarise(rmse = sqrt(mean((kp_pred - kp_actual)^2)), .groups = "drop")
  base_rmse <- rmse_by_model$rmse[rmse_by_model$.model == baseline_model]
  rmse_by_model |> dplyr::mutate(skill_vs_naive = 1 - rmse / base_rmse)
}

#' Brier score for storm forecasts: P(Kp >= threshold) vs. what actually
#' happened, compared against climatology (the storm's base rate -- the
#' simplest possible probability forecast). A Brier Skill Score above 0 means
#' the model adds real information beyond "how often does this happen anyway".
brier_skill <- function(scored, train, threshold) {
  climatology_p <- mean(train$kp >= threshold, na.rm = TRUE)
  scored <- scored |>
    dplyr::mutate(actual = dplyr::if_else(kp_actual >= threshold, 1, 0)) |>
    dplyr::filter(!is.na(actual))

  scored |>
    dplyr::group_by(.model) |>
    dplyr::summarise(
      brier = mean((p_storm - actual)^2),
      brier_climatology = mean((climatology_p - actual)^2),
      n_storm_periods = sum(actual), n_periods = dplyr::n(),
      .groups = "drop"
    ) |>
    dplyr::mutate(brier_skill_score = 1 - brier / brier_climatology)
}
