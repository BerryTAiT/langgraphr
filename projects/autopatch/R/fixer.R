# fixer.R - deterministic rule-based fixer + LLM output validation.
# The rule fixer is the guaranteed-convergence fallback: when LLM attempts
# are exhausted (or --no-llm), these rewrites produce a test-passing file
# for every defect class the scanner detects as critical.

strip_fences <- function(text) {
  t <- trimws(text)
  t <- sub("^```[A-Za-z]*\\s*", "", t)
  t <- sub("\\s*```$", "", t)
  trimws(t)
}

validate_candidate <- function(text) {
  if (is.null(text) || !is.character(text) || length(text) != 1L ||
      !nzchar(trimws(text))) {
    return(list(ok = FALSE, error = "empty candidate"))
  }
  err <- tryCatch({
    parse(text = text)
    NULL
  }, error = function(e) conditionMessage(e))
  if (!is.null(err)) return(list(ok = FALSE, error = err))
  list(ok = TRUE, error = "")
}

rule_fix <- function(content) {
  lines <- strsplit(content, "\n", fixed = TRUE)[[1]]

  # 1. Hardcoded secrets -> Sys.getenv() (must run BEFORE the = -> <- pass).
  lines <- vapply(lines, function(l) {
    if (!grepl('(?i)^[[:space:]]*[A-Za-z.][A-Za-z0-9._]*(key|password|passwd|secret|token)[[:space:]]*=[[:space:]]*"[^"]*"[[:space:]]*$', l, perl = TRUE)) {
      return(l)
    }
    sub('(?i)^([[:space:]]*)([A-Za-z.][A-Za-z0-9._]*)[[:space:]]*=[[:space:]]*"[^"]*"[[:space:]]*$',
        '\\1\\2 <- Sys.getenv("AUTOPATCH_\\U\\2\\E", "")', l, perl = TRUE)
  }, character(1), USE.NAMES = FALSE)

  # 2. eval(parse(text = "literal")) -> the literal code, inlined.
  lines <- gsub('eval\\s*\\(\\s*parse\\s*\\(\\s*text\\s*=\\s*"([^"]*)"\\s*\\)\\s*\\)',
                '\\1', lines, perl = TRUE)

  # 3. eval(parse(text = variable)) -> stop() (cannot be statically resolved).
  lines <- gsub('eval\\s*\\(\\s*parse\\s*\\(\\s*text\\s*=\\s*[A-Za-z.][A-Za-z0-9._]*\\s*\\)\\s*\\)',
                'stop("eval() removed by AutoPatch: unsafe dynamic evaluation")',
                lines, perl = TRUE)

  # 4. .Internal(sort(x, FALSE)) -> sort(x).
  lines <- gsub('\\.Internal\\s*\\(\\s*sort\\s*\\(([^,]*),[^)]*\\)\\s*\\)',
                'sort(\\1)', lines, perl = TRUE)

  # 5. 1:nrow(df) / 1:length(x) -> seq_len(...).
  for (fn in c("nrow", "ncol", "NROW", "NCOL", "length")) {
    lines <- gsub(
      sprintf('(?<![0-9.:])1[[:space:]]*:[[:space:]]*%s[[:space:]]*\\(([^)]*)\\)', fn),
      sprintf('seq_len(%s(\\1))', fn), lines, perl = TRUE)
  }

  # 6. name = value -> name <- value (top-level and indented assignments;
  #    == comparisons and named call arguments like c(x = 1) do not match).
  lines <- gsub('^([[:space:]]*)([A-Za-z.][A-Za-z0-9._]*)[[:space:]]*=[[:space:]]*([^=].*)$',
                '\\1\\2 <- \\3', lines, perl = TRUE)

  # 7. T/F literals -> TRUE/FALSE.
  lines <- gsub('\\bT\\b', 'TRUE', lines, perl = TRUE)
  lines <- gsub('\\bF\\b', 'FALSE', lines, perl = TRUE)

  paste0(lines, collapse = "\n")
}
