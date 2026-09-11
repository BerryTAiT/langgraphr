.args <- commandArgs(trailingOnly = TRUE)
cand <- if (length(.args) >= 1) .args[[1]] else Sys.getenv("AUTOPATCH_CANDIDATE")
stress <- if (length(.args) >= 2 && .args[[2]] == "stress") TRUE else
  Sys.getenv("AUTOPATCH_STRESS") == "1"
stopifnot(nzchar(cand))
source(cand)

res <- row_seq(data.frame())
if (!identical(as.integer(res), integer(0))) {
  stop("row_seq(data.frame()) returned c(", paste(res, collapse = ", "),
       ") instead of integer(0). The 1:nrow() pattern is fragile when the ",
       "frame is empty - use seq_len(nrow(df)).")
}
stopifnot(identical(as.integer(row_seq(data.frame(a = 1:3))), 1:3))
stopifnot(identical(make_label("run", 3), c("run_1", "run_2", "run_3")))
stopifnot(is.numeric(col_means_df(data.frame(a = c(1, 2)))))

if (stress) {
  code <- readLines(cand, warn = FALSE)
  if (any(grepl("^[[:space:]]*[A-Za-z.][A-Za-z0-9._]*[[:space:]]*=[^=]", code))) {
    stop("Style violation: '=' assignment found (use '<-').")
  }
}
