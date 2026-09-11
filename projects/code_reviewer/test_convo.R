# test_convo.R — Multi-turn conversation test
script_dir <- "c:/Users/berry/Desktop/creatingWrapper For LangGraph/projects/code_reviewer"

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

source(file.path(script_dir, "R", "modules_compat.R"), local = FALSE)
source(file.path(script_dir, "R", "tools.R"), local = TRUE)
source(file.path(script_dir, "R", "agent.R"), local = TRUE)

agent <- code_reviewer_agent(verbose = FALSE)

code <- "my_func <- function(x, y) {\n  z <- x + y\n  if (z > 10) {\n    return(z * 2)\n  } else {\n    return(z)\n  }\n}"
set_code(code)

cat("=== Turn 1: Review code ===\n")
r1 <- agent$invoke(paste0("Review this R code:\n\n", code))
cat(r1, "\n\n")

cat("=== Turn 2: Follow-up ===\n")
r2 <- agent$invoke("what about the complexity?")
cat(r2, "\n\n")

cat("=== Turn 3: Refactor ===\n")
r3 <- agent$invoke("can you refactor it?")
cat(r3, "\n")
