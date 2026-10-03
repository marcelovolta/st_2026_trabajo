# ---- Build/refresh the local GFZ Kp history cache -------------------------------
# Run this once before fit_baseline.R, and again occasionally to pick up newly
# finalized months. Safe to re-run: it only fetches years not already cached.
#
#   Rscript fetch_historical_kp.R

if (!file.exists("R/config.R")) stop("Run this script from the analysis/ folder.")
for (f in list.files("R", pattern = "\\.R$", full.names = TRUE)) source(f)

cfg <- load_config()
refresh_kp_history_cache(cfg)
