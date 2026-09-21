# ---- Small helpers -----------------------------------------------------------

# Current time as an ISO-8601 UTC string, e.g. "2026-09-21T11:30:00Z".
# All timestamps in the database are UTC, so there is no daylight-saving or
# time-zone ambiguity when you analyze or share the data.
now_utc <- function() {
  format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

# Timestamped log line on stdout. Under systemd this ends up in the journal
# (`journalctl -u spacewx-collector`); under launchd it goes to logs/collector.log.
log_msg <- function(level, ...) {
  cat(sprintf("%s %-5s %s\n", now_utc(), level, paste0(...)))
  flush.console()
}

# Tell an external "dead man's switch" (e.g. healthchecks.io) that the run
# finished. If the pings STOP arriving, the service emails you -- this is how you
# find out the machine is off or the collector is broken. Never fails the run.
ping_healthcheck <- function(url, ok = TRUE) {
  if (!nzchar(url)) return(invisible(FALSE))  # not configured: do nothing
  target <- if (ok) url else paste0(sub("/$", "", url), "/fail")
  tryCatch({
    httr2::request(target) |>
      httr2::req_timeout(10) |>
      httr2::req_retry(max_tries = 2) |>
      httr2::req_perform()
    invisible(TRUE)
  }, error = function(e) {
    log_msg("WARN", "healthcheck ping failed: ", conditionMessage(e))
    invisible(FALSE)
  })
}
