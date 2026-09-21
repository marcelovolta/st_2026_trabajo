# ---- Database (SQLite) -------------------------------------------------------
# SQLite = one file, no server to install, identical on your Mac and on the VPS.
# We only use DBI + standard SQL, so moving to PostgreSQL later means changing
# db_connect() and a few type names, not the collector logic.

# Table definitions. `CREATE TABLE IF NOT EXISTS` makes db_init() safe to run on
# every start: it creates the tables the first time and does nothing afterwards.
#
# Each observation table has PRIMARY KEY (time_tag, source): re-downloading the
# same minute is therefore harmless -- the database rejects the duplicate.
# `ingested_at` records when *we* stored the row (useful to audit outages).
SCHEMA <- c(
  "CREATE TABLE IF NOT EXISTS wind (
     time_tag           TEXT NOT NULL,   -- observation time, UTC
     source             TEXT NOT NULL,   -- spacecraft: SOLAR1 / ACE / IMAP
     active             INTEGER,         -- 1 = NOAA's operational source
     proton_speed       REAL,            -- km/s
     proton_density     REAL,            -- particles/cm^3
     proton_temperature REAL,            -- Kelvin
     overall_quality    INTEGER,         -- NOAA quality flag (0 = good)
     ingested_at        TEXT NOT NULL,
     PRIMARY KEY (time_tag, source)
   ) WITHOUT ROWID",

  "CREATE TABLE IF NOT EXISTS mag (
     time_tag        TEXT NOT NULL,
     source          TEXT NOT NULL,
     active          INTEGER,
     bt              REAL,               -- total field strength, nT
     bx_gsm          REAL,               -- field components in GSM coordinates, nT
     by_gsm          REAL,
     bz_gsm          REAL,               -- negative Bz = storm-driving
     overall_quality INTEGER,
     ingested_at     TEXT NOT NULL,
     PRIMARY KEY (time_tag, source)
   ) WITHOUT ROWID",

  "CREATE TABLE IF NOT EXISTS kp (
     time_tag      TEXT NOT NULL PRIMARY KEY,  -- start of the 3-hour period, UTC
     kp            REAL,                       -- 0-9 geomagnetic activity index
     a_running     INTEGER,
     station_count INTEGER,
     ingested_at   TEXT NOT NULL               -- last time we wrote this row
   ) WITHOUT ROWID",

  # One row per feed per run. Answers 'did it work?' and 'when was the outage?'.
  "CREATE TABLE IF NOT EXISTS ingest_log (
     id            INTEGER PRIMARY KEY AUTOINCREMENT,
     run_at        TEXT NOT NULL,
     feed          TEXT NOT NULL,
     status        TEXT NOT NULL,      -- 'ok' or 'error'
     rows_fetched  INTEGER,            -- rows NOAA sent us
     rows_new      INTEGER,            -- rows that were actually new to us
     newest_time   TEXT,               -- latest observation time in the payload
     message       TEXT                -- error text when status = 'error'
   )"
)

# Open the database file (creating the folder and file if needed).
db_connect <- function(path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  # WAL mode: your analysis code can READ the file while the collector WRITES,
  # and a crash mid-write cannot corrupt the database.
  DBI::dbGetQuery(con, "PRAGMA journal_mode = WAL")
  # If another process holds the file, wait up to 10 s instead of failing.
  DBI::dbGetQuery(con, "PRAGMA busy_timeout = 10000")
  con
}

# Create the tables if they do not exist yet.
db_init <- function(con) {
  for (statement in SCHEMA) DBI::dbExecute(con, statement)
  invisible(con)
}

# Insert a data frame into `table`. Returns how many rows were written.
#
#   update = FALSE: a row whose key already exists is silently skipped
#                   (INSERT ... ON CONFLICT DO NOTHING). This is what makes
#                   overlapping downloads and restarts safe.
#   update = TRUE:  an existing row is overwritten with the new values.
#
# Everything happens in one transaction: either all rows are stored or none.
upsert_rows <- function(con, table, df, key, update = FALSE) {
  cols <- names(df)
  action <- if (update) {
    to_update <- setdiff(cols, key)
    # Only rewrite a row if one of its VALUES changed (ingested_at is ignored in
    # the comparison), so the "rows new" count in the log means real changes.
    # `IS NOT` is SQLite's NULL-safe "not equal".
    compare <- setdiff(to_update, "ingested_at")
    paste("DO UPDATE SET",
          paste0(to_update, " = excluded.", to_update, collapse = ", "),
          "WHERE",
          paste0(compare, " IS NOT excluded.", compare, collapse = " OR "))
  } else {
    "DO NOTHING"
  }
  sql <- sprintf(
    "INSERT INTO %s (%s) VALUES (%s) ON CONFLICT (%s) %s",
    table,
    paste(cols, collapse = ", "),
    paste(rep("?", length(cols)), collapse = ", "),  # one placeholder per column
    paste(key, collapse = ", "),
    action
  )
  # `params` is a list of column vectors: SQLite runs the statement once per row.
  DBI::dbWithTransaction(
    con,
    DBI::dbExecute(con, sql, params = unname(as.list(df)))
  )
}

# Record the outcome of one feed in one run.
log_ingest <- function(con, feed, status, fetched = NA_integer_,
                       new = NA_integer_, newest = NA_character_,
                       message = NA_character_) {
  DBI::dbExecute(
    con,
    "INSERT INTO ingest_log
       (run_at, feed, status, rows_fetched, rows_new, newest_time, message)
     VALUES (?, ?, ?, ?, ?, ?, ?)",
    params = list(now_utc(), feed, status, fetched, new, newest, message)
  )
}
