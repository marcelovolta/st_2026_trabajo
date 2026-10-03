# ---- Models ---------------------------------------------------------------------
# Three candidates, deliberately in increasing complexity:
#   1. NAIVE      "Kp will be whatever it is right now" -- the baseline everything
#                 else has to beat. A university paper reports skill AGAINST
#                 this, never raw accuracy (storms are rare, so "always predict
#                 quiet" already looks accurate without being useful).
#   2. ETS        Exponential smoothing: a short-memory, self-tuning model.
#   3. ARIMA      Autoregressive model: captures the same short-memory
#                 persistence ETS does, but can also pick up structure ETS
#                 can't (e.g. faster/slower decay after a spike).
#
# Deliberately NOT included yet, to keep this baseline simple (see project
# discussion): a 27-day Fourier seasonal term, and solar wind/Bz as exogenous
# regressors. Both slot into fit_kp_models() as one more formula term, in
# `fabletools::model(...)`, without restructuring anything else -- see the
# comment at the bottom of this file for exactly how.

#' Fit all three candidate models on a training tsibble (must have columns
#' `time`, `kp`, indexed by `time`).
fit_kp_models <- function(train) {
  train |>
    fabletools::model(
      naive = fable::NAIVE(kp),
      ets   = fable::ETS(kp),
      arima = fable::ARIMA(kp)
    )
}

#' Forecast `h` steps (3-hour periods) ahead from fitted models.
forecast_kp <- function(fit, h) {
  fabletools::forecast(fit, h = h)
}

#' Turn a forecast distribution for Kp into P(storm), i.e. P(Kp >= threshold),
#' using the model's own predictive distribution (assumed Gaussian, as fable
#' returns by default) rather than just its point forecast. This is what makes
#' the output a *likelihood*, not just a predicted value.
storm_probability <- function(fc, threshold) {
  # distributional::cdf() already returns one value per row (a plain numeric
  # vector, not a list) -- indexing it with [[1]] would silently take only the
  # FIRST row's value and let mutate() recycle it across every row, which is
  # exactly the bug this comment is here to stop someone from reintroducing.
  fc |>
    dplyr::mutate(
      p_storm = 1 - distributional::cdf(kp, threshold),
      # Clamp: Kp is bounded at 9, so extrapolated tail probability near the
      # top of the scale can slightly exceed 1 under a Gaussian assumption.
      p_storm = pmin(pmax(p_storm, 0), 1)
    )
}

# ---- How the two deferred extensions would slot in -------------------------------
#
# 27-day seasonal term (recurrent high-speed streams), as a Fourier regressor
# rather than literal SARIMA(s=216) -- the standard approach for long seasonal
# periods (Hyndman & Athanasopoulos, Forecasting: Principles and Practice):
#
#   train |> fabletools::model(arima_seasonal = fable::ARIMA(kp ~ fourier(period = 216, K = 4)))
#
# Solar wind / Bz as exogenous predictors (once the collector-reading code
# exists on the analysis side), as a dynamic regression -- same `model()`
# call, one more formula term, everything else (forecasting, backtesting,
# storm probability) unchanged:
#
#   train |> fabletools::model(arimax = fable::ARIMA(kp ~ speed + bz + coupling_fn))
