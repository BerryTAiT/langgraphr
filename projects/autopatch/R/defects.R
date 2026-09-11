# defects.R - defect detection rules for AutoPatch.
# scan_defects() returns a list of records (NOT a data frame - records cross
# the langgraphr bridge as JSON, and data frames are the known mangling bug).

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L) y else x

scan_defects <- function(content) {
  lines <- strsplit(content, "\n", fixed = TRUE)[[1]]
  rules <- list(
    list(id = "hardcoded_secret", category = "security", severity = "critical",
         pattern = '(?i)^[[:space:]]*[A-Za-z.][A-Za-z0-9._]*(key|password|passwd|secret|token)[[:space:]]*=[[:space:]]*"[^"]*"',
         desc = "Hardcoded credential literal - move to Sys.getenv()"),
    list(id = "eval_parse", category = "security", severity = "critical",
         pattern = 'eval\\s*\\(\\s*parse\\s*\\(',
         desc = "eval(parse()) - unsafe dynamic code execution"),
    list(id = "internal_call", category = "portability", severity = "critical",
         pattern = '\\.Internal\\s*\\(',
         desc = ".Internal() call - use the public base function"),
    list(id = "fragile_seq", category = "correctness", severity = "critical",
         pattern = '(?<![0-9.:])1[[:space:]]*:[[:space:]]*(nrow|ncol|NROW|NCOL|length)[[:space:]]*\\(',
         desc = "Fragile 1:nrow()/1:length() - use seq_len()"),
    list(id = "eq_assignment", category = "style", severity = "advisory",
         pattern = '^[[:space:]]*[A-Za-z.][A-Za-z0-9._]*[[:space:]]*=[^=]',
         desc = "Use <- instead of = for assignment"),
    list(id = "tf_literal", category = "style", severity = "advisory",
         pattern = '\\bT\\b|\\bF\\b',
         desc = "Use TRUE/FALSE, not the T/F globals"),
    list(id = "sapply_use", category = "robustness", severity = "advisory",
         pattern = '\\bsapply\\s*\\(',
         desc = "Prefer vapply() for type-stable results"),
    list(id = "paste_sep", category = "modernization", severity = "advisory",
         pattern = 'paste\\([^)]*sep[[:space:]]*=',
         desc = "Prefer paste0() over paste(..., sep = ...)")
  )
  out <- list()
  for (rule in rules) {
    hits <- grepl(rule$pattern, lines, perl = TRUE)
    if (any(hits)) {
      for (ln in which(hits)) {
        out <- c(out, list(list(
          id = rule$id,
          category = rule$category,
          severity = rule$severity,
          line = as.integer(ln),
          desc = rule$desc,
          evidence = trimws(substr(lines[[ln]], 1L, 60L))
        )))
      }
    }
  }
  out
}
