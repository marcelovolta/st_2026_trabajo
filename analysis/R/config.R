# ---- Configuration -------------------------------------------------------------
# Settings for the Kp-only baseline. Environment variables let the same code run
# unchanged on the Mac and later elsewhere; see ../.env.example in the collector.

load_config <- function() {
  list(
    # Live, recent Kp: read from the COLLECTOR's database (the shared schema the
    # two projects agreed on). Default assumes this project sits next to it, as
    # `analysis/` does in this repo.
    collector_db_path = Sys.getenv("SPACEWX_DB_PATH", unset = "../data/spacewx.sqlite"),

    # Deep history: GFZ Potsdam, the official source of the Kp index (data since
    # 1932, CC BY 4.0). We cache it locally rather than re-downloading on every
    # run -- it only grows a little each day, and re-fetching 90+ years of data
    # every time would be slow and inconsiderate to a free academic service.
    gfz_api_url  = "https://kp.gfz.de/app/json/",
    history_cache = "data/kp_history.csv",
    # Fetch in chunks this many years wide, with a short pause between requests,
    # so one run doesn't hit the API with a single very large request or hammer
    # it with many small ones.
    history_chunk_years = 10,
    history_start = "1932-01-01",

    # Kp >= this value counts as a storm (NOAA's G1 threshold).
    storm_threshold = 5,

    # Forecast horizon for the baseline models, in 3-hour steps (4 = 12 hours).
    horizon_steps = 4,

    # How much history to actually fit on. ETS/ARIMA's actual memory for a
    # series like this operates on hours to weeks (see the autocorrelation
    # discussion in the project write-up), not years, so a multi-decade
    # training window buys little beyond a much slower fit. 5 years is still
    # ample for a 3-hourly series and keeps each backtest fold fast.
    train_years = 5,

    # Rolling-origin backtest: how much of the recent data to hold out for
    # evaluation, and how many 3-hour steps between folds. Each fold refits
    # all three models from scratch on a `train_years` window, so both numbers
    # trade statistical reliability (more/closer-together origins) against
    # runtime -- see ANALYSIS.md for how to widen them for a final report.
    backtest_years = 3,
    backtest_step   = 8 * 60
  )
}
