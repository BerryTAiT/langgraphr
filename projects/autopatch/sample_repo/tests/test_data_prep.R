.args <- commandArgs(trailingOnly = TRUE)
cand <- if (length(.args) >= 1) .args[[1]] else Sys.getenv("AUTOPATCH_CANDIDATE")
stress <- if (length(.args) >= 2 && .args[[2]] == "stress") TRUE else
  Sys.getenv("AUTOPATCH_STRESS") == "1"
stopifnot(nzchar(cand))
source(cand)

tmp <- file.path(tempdir(), "cfg.ini")
writeLines(c("mode = prod", "workers = 4"), tmp)
cfg <- load_config(tmp)
stopifnot(identical(cfg$mode, "prod"), identical(cfg$workers, "4"))
stopifnot(isTRUE(flag_ready(cfg)))
stopifnot(isFALSE(flag_ready(list())))

if (stress) {
  code <- readLines(cand, warn = FALSE)
  if (any(grepl("^[[:space:]]*[A-Za-z.][A-Za-z0-9._]*[[:space:]]*=[^=]", code))) {
    stop("Style violation: '=' assignment found (use '<-').")
  }
  if (any(grepl("\\bT\\b|\\bF\\b", code, perl = TRUE))) {
    stop("Style violation: bare T/F literal found (use TRUE/FALSE).")
  }
}
