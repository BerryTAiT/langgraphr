.args <- commandArgs(trailingOnly = TRUE)
cand <- if (length(.args) >= 1) .args[[1]] else Sys.getenv("AUTOPATCH_CANDIDATE")
stopifnot(nzchar(cand))
code <- paste(readLines(cand, warn = FALSE), collapse = "\n")

if (grepl("eval\\s*\\(\\s*parse\\s*\\(", code)) {
  stop("Security violation: eval(parse()) found - replace with direct code.")
}
if (grepl("\\.Internal", code)) {
  stop("Portability violation: .Internal() found - use the public base function.")
}

source(cand)
stopifnot(identical(double_it(21), 42))
stopifnot(identical(old_sort(c(3, 1, 2)), c(1, 2, 3)))
