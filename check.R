# ---- Health report for the collected data ------------------------------------
# Run:  Rscript check.R
# Shows how much data there is, how fresh it is, recent runs, and any gaps.
# It only READS the database, so it is safe to run while the collector is active.

source("R/utils.R")
source("R/config.R")
source("R/db.R")

if (file.exists(".env")) readRenviron(".env")
cfg <- load_config()
if (!file.exists(cfg$db_path)) stop("No database yet at ", cfg$db_path, ". Run collect.R first.")

con <- DBI::dbConnect(RSQLite::SQLite(), cfg$db_path, flags = RSQLite::SQLITE_RO)
on.exit(DBI::dbDisconnect(con))

cat("Database:", cfg$db_path, "\n\n")

# 1. Rows and time span per table.
cat("== Tables ==\n")
print(DBI::dbGetQuery(con, "
  SELECT 'wind' AS tbl, COUNT(*) AS rows, MIN(time_tag) AS first, MAX(time_tag) AS last FROM wind
  UNION ALL SELECT 'mag', COUNT(*), MIN(time_tag), MAX(time_tag) FROM mag
  UNION ALL SELECT 'kp',  COUNT(*), MIN(time_tag), MAX(time_tag) FROM kp"))

# 2. Rows per spacecraft (the three report in parallel).
cat("\n== Wind rows per source ==\n")
print(DBI::dbGetQuery(con, "SELECT source, active, COUNT(*) AS rows FROM wind GROUP BY source, active"))

# 3. The most recent runs. Look for status = 'error'.
cat("\n== Last 6 log entries ==\n")
print(DBI::dbGetQuery(con, "SELECT run_at, feed, status, rows_fetched, rows_new, message
                            FROM ingest_log ORDER BY id DESC LIMIT 6"))

# 4. Gaps: stretches longer than 5 minutes with no wind data from any source.
#    These are the outages that the 24 h backfill could not repair.
cat("\n== Gaps in wind data (> 5 min) ==\n")
minutes <- DBI::dbGetQuery(con, "SELECT DISTINCT substr(time_tag, 1, 16) AS t FROM wind ORDER BY t")$t
if (length(minutes) < 2) {
  cat("Not enough data yet.\n")
} else {
  t <- as.POSIXct(minutes, format = "%Y-%m-%dT%H:%M", tz = "UTC")
  diff_min <- as.numeric(diff(t), units = "mins")
  big <- which(diff_min > 5)
  if (length(big) == 0) {
    cat("None.\n")
  } else {
    print(data.frame(gap_start = format(t[big]), gap_end = format(t[big + 1]),
                     minutes = diff_min[big]))
  }
}
