# ---- Download + store one feed -----------------------------------------------

# Download a JSON feed and parse it into a data frame.
#
# The download AND the parsing are retried together (up to cfg$max_tries times,
# waiting 2 s, then 4 s, ...). That matters because NOAA sometimes serves a
# truncated file with HTTP status 200 while it is rewriting it: the download
# "succeeds" but parsing fails ("premature EOF"). Retrying a moment later
# gets the complete file, so a transient glitch is not counted as a failure.
# The same loop covers timeouts, network errors and HTTP error codes.
fetch_feed <- function(url, cfg) {
  last_error <- NULL
  for (attempt in seq_len(cfg$max_tries)) {
    result <- tryCatch({
      resp <- httr2::request(url) |>
        httr2::req_user_agent(cfg$user_agent) |>
        httr2::req_timeout(cfg$timeout_s) |>
        httr2::req_perform()
      # A JSON array of objects becomes a data frame; JSON `null` becomes NA.
      jsonlite::fromJSON(httr2::resp_body_string(resp))
    }, error = function(e) e)

    if (!inherits(result, "error")) return(result)

    last_error <- result
    if (attempt < cfg$max_tries) {
      log_msg("WARN", sprintf("attempt %d/%d failed (%s); retrying",
                              attempt, cfg$max_tries,
                              trimws(strsplit(conditionMessage(result), "\n")[[1]][1])))
      Sys.sleep(2^attempt)
    }
  }
  stop(last_error)  # every attempt failed: let the caller record the error
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
