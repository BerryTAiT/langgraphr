# test_runner.R - execute a sample repo's test file against a CANDIDATE
# version of an R file, in a fresh Rscript subprocess (the AutoPatch
# "run tests -> capture stderr -> re-prompt" loop), plus a base-R line diff.

run_tests <- function(file, content) {
  repo <- dirname(dirname(file))
  test_file <- file.path(repo, "tests", paste0("test_", basename(file)))
  if (!file.exists(test_file)) {
    return(list(ok = TRUE, log = "(no test file - accepted as-is)"))
  }
  cand_dir <- file.path(tempdir(), "autopatch_candidate")
  dir.create(cand_dir, recursive = TRUE, showWarnings = FALSE)
  cand <- file.path(cand_dir, basename(file))
  writeLines(content, cand)

  # system2(env=) is broken on Windows; pass the candidate path and the
  # stress flag as command-line arguments instead (portable everywhere).
  rscript <- file.path(R.home("bin"), "Rscript")
  stress <- if (getOption("autopatch.stress", FALSE)) "stress" else "normal"
  cmd <- paste(shQuote(rscript),
               shQuote(normalizePath(test_file, winslash = "/")),
               shQuote(normalizePath(cand, winslash = "/")),
               stress)
  out <- suppressWarnings(system(cmd, intern = TRUE))
  status <- attr(out, "status")
  ok <- is.null(status) || identical(as.integer(status), 0L)
  list(ok = ok, log = paste(if (is.null(out)) "" else out, collapse = "\n"))
}

# lcs_diff - unified-style line diff via longest common subsequence.
# Small files only (O(n*m)); sample repo files are tens of lines.
lcs_diff <- function(a, b) {
  a <- as.character(a)
  b <- as.character(b)
  n <- length(a)
  m <- length(b)
  dp <- matrix(0L, nrow = n + 1L, ncol = m + 1L)
  for (i in seq_len(n)) {
    for (j in seq_len(m)) {
      dp[i + 1L, j + 1L] <- if (identical(a[i], b[j])) {
        dp[i, j] + 1L
      } else {
        max(dp[i + 1L, j], dp[i, j + 1L])
      }
    }
  }
  out <- character(0)
  i <- n
  j <- m
  while (i > 0L || j > 0L) {
    if (i > 0L && j > 0L && identical(a[i], b[j])) {
      out <- c(paste0("  ", a[i]), out)
      i <- i - 1L
      j <- j - 1L
    } else if (j > 0L && (i == 0L || dp[i + 1L, j] >= dp[i, j + 1L])) {
      out <- c(paste0("+ ", b[j]), out)
      j <- j - 1L
    } else {
      out <- c(paste0("- ", a[i]), out)
      i <- i - 1L
    }
  }
  out
}

content_lines <- function(content) strsplit(content, "\n", fixed = TRUE)[[1]]
