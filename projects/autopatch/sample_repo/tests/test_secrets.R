.args <- commandArgs(trailingOnly = TRUE)
cand <- if (length(.args) >= 1) .args[[1]] else Sys.getenv("AUTOPATCH_CANDIDATE")
stopifnot(nzchar(cand))
code <- readLines(cand, warn = FALSE)

if (any(grepl("sk-live-|hunter2", code))) {
  stop("Security violation: hardcoded credential literal found. ",
       "Move secrets to Sys.getenv() calls.")
}

source(cand)
stopifnot(identical(fetch_status("http://127.0.0.1:1/none"), "unavailable"))
