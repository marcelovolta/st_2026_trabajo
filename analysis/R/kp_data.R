# ---- Kp data: historical archive + live continuation --------------------------
# Two sources, two jobs:
#   - GFZ Potsdam (the official Kp archive): long, stable history for TRAINING
#     a model. Cached locally after the first fetch.
#   - Our own collector's database: the LIVE continuation, for forecasting and
#     evaluating against what actually happens now. This is the one place the
#     two projects touch -- the analysis project only ever *reads* it.

# ---- Historical archive (GFZ) ---------------------------------------------------

#' One chunk of GFZ's Kp API, as a two-column data frame (time, kp).
#' status = "def" means "definitive": GFZ's finalized, reprocessed value, not
#' subject to later revision. status = NULL returns whatever is available,
#' including not-yet-finalized "pre" values -- used only for the short bridge
#' below, never cached, since a preliminary value can still be revised.
fetch_gfz_chunk <- function(cfg, start, end, status = "def") {
  req <- httr2::request(cfg$gfz_api_url) |>
    httr2::req_url_query(
      start = format(start, "%Y-%m-%dT%H:%M:%SZ"),
      end   = format(end,   "%Y-%m-%dT%H:%M:%SZ"),
      index = "Kp"
    )
  if (!is.null(status)) req <- httr2::req_url_query(req, status = status)
  resp <- req |> httr2::req_timeout(60) |> httr2::req_retry(max_tries = 3) |> httr2::req_perform()
  d <- httr2::resp_body_json(resp, simplifyVector = TRUE)
  if (length(d$Kp) == 0) return(data.frame(time = as.POSIXct(character()), kp = numeric()))
  data.frame(time = as.POSIXct(d$datetime, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"), kp = d$Kp)
}

#' Build or refresh the local historical cache. Only fetches the years not
#' already cached, so a second run is near-instant and polite to the API.
refresh_kp_history_cache <- function(cfg) {
  dir.create(dirname(cfg$history_cache), recursive = TRUE, showWarnings = FALSE)

  existing <- if (file.exists(cfg$history_cache)) {
    d <- read.csv(cfg$history_cache)
    # An explicit format is essential here: write.csv() renders a midnight
    # POSIXct as a bare date ("1932-01-01", no "00:00:00"), and as.POSIXct()
    # WITHOUT a format= auto-detects a single format from the first row --
    # if that row happens to be a midnight timestamp, every other row's
    # time-of-day then gets silently truncated to midnight too.
    d$time <- as.POSIXct(d$time, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    d
  } else {
    data.frame(time = as.POSIXct(character()), kp = numeric())
  }

  start <- as.POSIXct(cfg$history_start, tz = "UTC")
  if (nrow(existing) > 0) start <- max(existing$time) + 3 * 3600  # resume after the cache's last point
  # Leave a margin before "now": GFZ takes roughly a month to finalize a period
  # to "def" status (observed: requesting up to 7 days ago still returned
  # nothing newer than ~5 weeks back), so recent weeks are never available yet
  # -- that gap is exactly what the collector's live `kp` table is for.
  end <- Sys.time() - 35 * 86400
  if (start >= end) {
    cat("Historical cache already up to date (through", format(max(existing$time)), "UTC).\n")
    return(invisible(existing))
  }

  chunk_days <- cfg$history_chunk_years * 365
  starts <- seq(start, end, by = chunk_days * 86400)
  new_chunks <- list()
  for (i in seq_along(starts)) {
    chunk_end <- min(starts[i] + chunk_days * 86400 - 1, end)
    cat(sprintf("Fetching %s to %s ...\n", format(starts[i], "%Y-%m-%d"), format(chunk_end, "%Y-%m-%d")))
    new_chunks[[i]] <- fetch_gfz_chunk(cfg, starts[i], chunk_end)
    if (i < length(starts)) Sys.sleep(1)  # be polite to a free academic API
  }

  combined <- rbind(existing, do.call(rbind, new_chunks))
  combined <- combined[!duplicated(combined$time), ]
  combined <- combined[order(combined$time), ]
  # Write time as an explicit, unambiguous ISO-8601 string (see the comment
  # above on load) rather than letting write.csv() pick a format per row.
  to_write <- combined
  to_write$time <- format(to_write$time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  write.csv(to_write, cfg$history_cache, row.names = FALSE)
  cat(sprintf("Cache now holds %d points, %s to %s.\n",
             nrow(combined), format(min(combined$time)), format(max(combined$time))))
  invisible(combined)
}

#' Read the cached historical archive. Call refresh_kp_history_cache() first
#' if it may not exist yet or may need new data appended.
load_kp_history <- function(cfg) {
  if (!file.exists(cfg$history_cache)) {
    stop("No historical cache at ", cfg$history_cache, ". Run fetch_historical_kp.R first.")
  }
  d <- read.csv(cfg$history_cache)
  d$time <- as.POSIXct(d$time, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")  # see note in refresh_kp_history_cache()
  d
}

# ---- Live continuation (the collector's database) ------------------------------

#' Read the Kp rows our own collector has stored, via the shared `kp` table.
#' This is the one point of contact between the two projects.
load_kp_live <- function(cfg) {
  if (!file.exists(cfg$collector_db_path)) {
    warning("Collector database not found at ", cfg$collector_db_path,
           " -- proceeding with historical data only.")
    return(data.frame(time = as.POSIXct(character()), kp = numeric()))
  }
  con <- DBI::dbConnect(RSQLite::SQLite(), cfg$collector_db_path, flags = RSQLite::SQLITE_RO)
  on.exit(DBI::dbDisconnect(con))
  d <- DBI::dbGetQuery(con, "SELECT time_tag, kp FROM kp ORDER BY time_tag")
  data.frame(time = as.POSIXct(d$time_tag, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"), kp = d$kp)
}

# ---- Combine into one regular tsibble -------------------------------------------

#' Historical (GFZ, definitive) up to its cutoff, then the collector's live
#' values after that -- so the model trains on finalized values and only the
#' most recent, still-provisional weeks come from our own feed.
#'
#' Returns a tsibble on a REGULAR 3-hour grid: tsibble::fill_gaps() inserts an
#' explicit NA for any missing period, rather than silently compressing time,
#' which models like ARIMA/ETS require to make sense of lags and seasonality.
#' Short gaps (up to `max_fill` steps) are linearly interpolated, as in the
#' collector's own exploration notebook; longer gaps are left as NA.
build_kp_series <- function(history, live, max_fill = 2) {
  if (nrow(live) > 0) {
    history <- history[history$time < min(live$time), ]
    combined <- rbind(history, live)
  } else {
    combined <- history
  }
  combined <- combined[!duplicated(combined$time), ]
  combined <- combined[order(combined$time), ]

  ts <- tsibble::tsibble(time = combined$time, kp = combined$kp, index = time) |>
    tsibble::fill_gaps()

  x <- ts$kp
  idx <- seq_along(x)
  filled <- stats::approx(idx[!is.na(x)], x[!is.na(x)], xout = idx, rule = 1)$y
  r <- rle(is.na(x)); e <- cumsum(r$lengths); s <- e - r$lengths + 1
  for (g in which(r$values & r$lengths > max_fill)) filled[s[g]:e[g]] <- NA
  ts$kp <- filled
  ts
}

# ---- Orchestration ---------------------------------------------------------------

#' The whole pipeline: cached GFZ history (definitive) + a short bridge of
#' preliminary GFZ data for the seam before the collector existed + the
#' collector's own live data, merged into one regular, gap-filled tsibble.
#'
#' The bridge exists because GFZ's definitive data lags ~5 weeks behind the
#' present, while the collector has only been running since it was deployed --
#' there's a real gap between the two that nothing else covers. Interpolating
#' across it would be dishonest (Kp over two real weeks is not a straight
#' line); fetching preliminary values for exactly that seam is not.
load_combined_kp_series <- function(cfg) {
  history <- load_kp_history(cfg)
  live    <- load_kp_live(cfg)

  bridge <- data.frame(time = as.POSIXct(character()), kp = numeric())
  if (nrow(live) > 0 && min(live$time) > max(history$time) + 3 * 3600) {
    cat(sprintf("Bridging %s to %s with GFZ preliminary data...\n",
               format(max(history$time)), format(min(live$time))))
    bridge <- fetch_gfz_chunk(cfg, max(history$time) + 3 * 3600, min(live$time) - 3 * 3600, status = NULL)
  }

  build_kp_series(rbind(history, bridge), live)
}
