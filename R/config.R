# ---- Configuration -----------------------------------------------------------
# Everything that differs between machines (your Mac mini vs. the VPS) comes from
# environment variables, so the code itself never has to change when deploying.
# See .env.example for the list of variables.

# NOAA Space Weather Prediction Center (SWPC): public, no API key needed.
SWPC_BASE <- "https://services.swpc.noaa.gov"

# Description of every feed we collect. `ingest_feed()` in R/ingest.R is generic:
# to collect a new feed, add an entry here and a table in R/db.R -- nothing else.
#
#   url      where to download the JSON (an array of objects, one per observation)
#   table    destination table in the database
#   columns  DB column name = field name in the JSON (we only keep these fields)
#   types    R/SQLite type for each DB column: "text", "int" or "real"
#   key      columns that uniquely identify a row (the table's PRIMARY KEY)
#   update   FALSE = keep the first value we saw and ignore repeats
#            TRUE  = overwrite when NOAA revises a value (used for Kp, which
#                    is an estimate that may be corrected after publication)
FEEDS <- list(
  # Solar wind plasma: speed, density, temperature. ~24 h of 1-minute data.
  # NOTE: several spacecraft (SOLAR1, ACE, IMAP) report in parallel, so the
  # same time_tag can appear once per `source`. That is why `source` is in the key.
  wind = list(
    url     = paste0(SWPC_BASE, "/json/rtsw/rtsw_wind_1m.json"),
    table   = "wind",
    columns = c(time_tag = "time_tag", source = "source", active = "active",
                proton_speed = "proton_speed", proton_density = "proton_density",
                proton_temperature = "proton_temperature",
                overall_quality = "overall_quality"),
    types   = c(time_tag = "text", source = "text", active = "int",
                proton_speed = "real", proton_density = "real",
                proton_temperature = "real", overall_quality = "int"),
    key     = c("time_tag", "source"),
    update  = FALSE
  ),

  # Interplanetary magnetic field. bz_gsm (north/south component) is the key
  # driver of geomagnetic storms: sustained negative Bz is what to watch.
  mag = list(
    url     = paste0(SWPC_BASE, "/json/rtsw/rtsw_mag_1m.json"),
    table   = "mag",
    columns = c(time_tag = "time_tag", source = "source", active = "active",
                bt = "bt", bx_gsm = "bx_gsm", by_gsm = "by_gsm", bz_gsm = "bz_gsm",
                overall_quality = "overall_quality"),
    types   = c(time_tag = "text", source = "text", active = "int",
                bt = "real", bx_gsm = "real", by_gsm = "real", bz_gsm = "real",
                overall_quality = "int"),
    key     = c("time_tag", "source"),
    update  = FALSE
  ),

  # Estimated planetary Kp index: the standard 0-9 measure of geomagnetic
  # activity, one value per 3 hours. This is the natural target for storm
  # forecasting. It is an NOAA estimate that can be revised, hence update = TRUE.
  kp = list(
    url     = paste0(SWPC_BASE, "/products/noaa-planetary-k-index.json"),
    table   = "kp",
    columns = c(time_tag = "time_tag", kp = "Kp", a_running = "a_running",
                station_count = "station_count"),
    types   = c(time_tag = "text", kp = "real", a_running = "int",
                station_count = "int"),
    key     = "time_tag",
    update  = TRUE
  )
)

# Read settings from environment variables (with defaults for local testing).
# It is a function, not a constant, because collect.R loads the optional .env
# file first and the values must be read *after* that.
load_config <- function() {
  list(
    # SQLite file. Relative paths are relative to the project root.
    db_path         = Sys.getenv("SPACEWX_DB_PATH", "data/spacewx.sqlite"),
    # Optional healthchecks.io-style URL, pinged after every run (see R/utils.R).
    healthcheck_url = Sys.getenv("SPACEWX_HEALTHCHECK_URL", ""),
    # Identifies us to NOAA's servers. Put a contact address here if you like.
    user_agent      = Sys.getenv("SPACEWX_USER_AGENT",
                                 "spacewx-collector (university class project)"),
    timeout_s       = 30,  # give up on a single HTTP request after 30 s
    max_tries       = 3,   # download+parse attempts per feed before reporting a failure
    feeds           = FEEDS
  )
}
