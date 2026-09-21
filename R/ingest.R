# ---- Download + store one feed -----------------------------------------------

# Download a JSON feed and parse it into a data frame.
# httr2 retries automatically on timeouts, network errors and HTTP 429/5xx
# (with growing waits between attempts), so a brief NOAA hiccup is not a failure.
fetch_feed <- function(url, cfg) {
  resp <- httr2::request(url) |>
    httr2::req_user_agent(cfg$user_agent) |>
    httr2::req_timeout(cfg$timeout_s) |>
    httr2::req_retry(max_tries = cfg$max_tries, retry_on_failure = TRUE) |>
    httr2::req_perform()
  # A JSON array of objects becomes a data frame; JSON `null` becomes NA.
  jsonlite::fromJSON(httr2::resp_body_string(resp))
}

# Convert a column to the type its database column expects.
coerce_type <- function(x, type) {
  switch(type,
    text = as.character(x),
    int  = as.integer(x),   # also maps TRUE/FALSE to 1/0
    real = as.numeric(x),
    stop("unknown column type: ", type)
  )
}

# Fetch one feed described in FEEDS (R/config.R) and store it.
# Errors are NOT caught here: the caller (collect.R) records them per feed.
ingest_feed <- function(con, spec, cfg) {
  raw <- fetch_feed(spec$url, cfg)

  # Fail loudly if NOAA changed the format. This has happened before: the old
  # solar-wind URLs now return 404 and the layout moved from a matrix to objects.
  if (!is.data.frame(raw) || nrow(raw) == 0) {
    stop("payload is empty or not a JSON array of objects")
  }
  missing_fields <- setdiff(spec$columns, names(raw))
  if (length(missing_fields) > 0) {
    stop("feed is missing expected fields: ",
         paste(missing_fields, collapse = ", "),
         " (has NOAA changed the format?)")
  }

  # Keep only the fields we store, rename them to our column names, fix types.
  df <- raw[, spec$columns, drop = FALSE]
  names(df) <- names(spec$columns)
  df[] <- Map(coerce_type, df, spec$types[names(df)])
  df$ingested_at <- now_utc()

  # Guard against duplicate keys inside a single payload.
  df <- df[!duplicated(df[spec$key]), , drop = FALSE]

  written <- upsert_rows(con, spec$table, df, spec$key, spec$update)

  list(fetched = nrow(df),
       new     = written,
       newest  = max(df$time_tag, na.rm = TRUE))  # ISO strings sort chronologically
}
