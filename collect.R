# ---- Space weather collector: ONE collection cycle ---------------------------
# Downloads every feed in R/config.R, stores new rows in SQLite, exits.
#
# Run it from the project root:   Rscript collect.R
#
# It is deliberately NOT an infinite loop. A scheduler (systemd timer on the VPS,
# launchd on macOS) runs it every 5 minutes. Benefits: a crash only loses one
# run, memory never accumulates, and after a reboot the scheduler simply resumes.
# The exit code is 0 if every feed succeeded and 1 otherwise, so the scheduler
# and the healthcheck can tell when something is wrong.

# Load our functions (config, database, download logic).
if (!file.exists("R/db.R")) {
  stop("Run this script from the project root (the folder that contains R/).")
}
for (f in list.files("R", pattern = "\\.R$", full.names = TRUE)) source(f)

run_collector <- function() {
  # Optional local settings file (never committed to git). On the VPS the same
  # variables come from the systemd unit instead; see COLLECTOR.md.
  if (file.exists(".env")) readRenviron(".env")
  cfg <- load_config()

  con <- db_connect(cfg$db_path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)  # always close the DB, even on error
  db_init(con)

  all_ok <- TRUE
  for (name in names(cfg$feeds)) {
    # tryCatch isolates failures: if one feed breaks, the others still run.
    result <- tryCatch(
      {
        r <- ingest_feed(con, cfg$feeds[[name]], cfg)
        log_ingest(con, name, "ok", r$fetched, r$new, r$newest)
        log_msg("INFO", sprintf("%-4s ok: %d rows fetched, %d new, newest %s",
                                name, r$fetched, r$new, r$newest))
        TRUE
      },
      error = function(e) {
        log_ingest(con, name, "error", message = conditionMessage(e))
        log_msg("ERROR", sprintf("%-4s failed: %s", name, conditionMessage(e)))
        FALSE
      }
    )
    all_ok <- all_ok && result
  }

  ping_healthcheck(cfg$healthcheck_url, ok = all_ok)
  all_ok
}

# `interactive()` is FALSE under Rscript, so this runs when scheduled but not
# when you source() the file inside RStudio (handy for testing run_collector()).
if (!interactive()) {
  ok <- run_collector()
  quit(status = if (ok) 0L else 1L)
}
