# test.R — Quick E2E test for Code Reviewer Agent
# Run: Rscript test.R

script_dir <- "c:/Users/berry/Desktop/creatingWrapper For LangGraph/projects/code_reviewer"

# Load .env
env_path <- file.path(script_dir, ".env")
if (file.exists(env_path)) {
  lines <- readLines(env_path, warn = FALSE)
  for (line in lines) {
    line <- trimws(line)
    if (!nchar(line) || startsWith(line, "#")) next
    eq_pos <- regexpr("=", line)
    if (eq_pos > 0) {
      key <- trimws(substr(line, 1, eq_pos - 1))
      val <- trimws(substr(line, eq_pos + 1, nchar(line)))
      val <- gsub('^"|^\'|"$|\'$', "", val)
      do.call(Sys.setenv, stats::setNames(list(val), key))
    }
  }
}

# Load compat helpers
source(file.path(script_dir, "R", "modules_compat.R"), local = FALSE)

# Load project files
source(file.path(script_dir, "R", "tools.R"), local = TRUE)
source(file.path(script_dir, "R", "agent.R"), local = TRUE)

# Load sample code
code <- paste(readLines(file.path(script_dir, "examples", "sample.R")), collapse = "\n")
set_code(code)

cat("=== Code Reviewer E2E Test ===\n\n")

agent <- code_reviewer_agent(verbose = FALSE)
cat("Model:", agent$model, "\n\n")

result <- agent$invoke(paste0("Review this R code:\n\n", code))

cat("=== Review ===\n")
cat(result, "\n\n")

cps <- agent$get_history()
cat(sprintf("%d checkpoint(s) saved.\n", length(cps)))
