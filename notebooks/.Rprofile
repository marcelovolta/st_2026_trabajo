# Notebooks live in a subfolder, but the package library (renv) belongs to the
# project root. R only reads the .Rprofile of the folder it starts in, so this
# file points renv at the parent folder. Without it, rendering a notebook would
# silently use whatever packages happen to be installed system-wide.
Sys.setenv(RENV_PROJECT = normalizePath(".."))
source("../renv/activate.R")
