# main.R — Code Reviewer Agent console entry point
# Pure R, no HTML/CSS/JS
#
# Run: Rscript main.R
# Or:  source("main.R") in R console
#
# Usage:
#   > Paste R code directly — the agent will review it
#   > Or type a question about code you already submitted
#   > /history  — show checkpoint history
#   > /reset    — start fresh
#   > /quit     — exit

# ---- Detect script directory ----
script_dir <- tryCatch({
  frame_files <- lapply(sys.frames(), function(f) f$ofile)
  non_null <- which(!sapply(frame_files, is.null))
  if (length(non_null) > 0) {
    dirname(normalizePath(frame_files[[non_null[1]]]))
  } else {
    for (c in c("projects/code_reviewer", "code_reviewer", ".")) {
      if (dir.exists(file.path(c, "R"))) return(normalizePath(c))
    }
    normalizePath(".")
  }
}, error = function(e) normalizePath("."))

# ---- Load .env ----
env_candidates <- c(
  file.path(script_dir, ".env"),
  file.path(dirname(script_dir), ".env"),
  file.path(dirname(dirname(script_dir)), ".env"),
  file.path(dirname(dirname(dirname(script_dir))), ".env"),
  "c:/Users/berry/Desktop/creatingWrapper For LangGraph/projects/data_detective/.env"
)
for (env_path in env_candidates) {
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
    break
  }
}

# ---- Load langgraphr ----
if (!requireNamespace("langgraphr", quietly = TRUE)) {
  stop("langgraphr not found. Run: devtools::install_local('LanggraphR')")
}

# ---- Load project files ----
source(file.path(script_dir, "R", "modules_compat.R"), local = FALSE)
source(file.path(script_dir, "R", "tools.R"), local = TRUE)
source(file.path(script_dir, "R", "agent.R"), local = TRUE)

# ---- Console loop ----
main <- function() {
  cat("\n========================================\n")
  cat("     Code Reviewer Agent v1.0\n")
  cat("     Powered by langgraphr + DeepSeek\n")
  cat("========================================\n\n")
  cat("Paste R code or ask about code you've submitted.\n")
  cat("Commands: /history  /reset  /quit\n\n")

  agent <- code_reviewer_agent(verbose = FALSE)
  buffer <- character(0)
  in_code <- FALSE

  repeat {
    prompt <- if (in_code) "  ... " else "> "
    line <- readline(prompt = prompt)
    if (is.null(line)) break

    trimmed <- trimws(line)

    # Commands (only outside code mode)
    if (!in_code && startsWith(trimmed, "/")) {
      cmd <- tolower(trimmed)
      if (cmd == "/quit") break
      if (cmd == "/reset") {
        agent$reset()
        buffer <- character(0)
        in_code <- FALSE
        cat("Reset.\n\n")
        next
      }
      if (cmd == "/history") {
        cps <- agent$get_history()
        if (length(cps) == 0) cat("No checkpoints.\n")
        else {
          cat(sprintf("%d checkpoint(s):\n", length(cps)))
          for (i in seq_along(cps))
            cat(sprintf("  #%d Step %d — %s\n", i,
                        cps[[i]]$metadata$step %||% 0,
                        cps[[i]]$metadata$label %||% ""))
        }
        next
      }
      cat("Unknown. Use /history /reset /quit\n")
      next
    }

    # Empty line in code mode = end of code
    if (in_code && nchar(trimmed) == 0) {
      code_str <- paste(buffer, collapse = "\n")
      buffer <- character(0)
      in_code <- FALSE
      if (!nzchar(code_str)) { next }

      set_code(code_str)
      cat("Analyzing...\n\n")
      result <- agent$invoke(paste0("Review this R code:\n\n", code_str))
      cat(result, "\n\n")
      next
    }

    # Detect if input looks like code
    is_code_like <- grepl(
      "<-|=\\s*function|function\\s*\\(|library\\(|read\\.|if\\s*\\(|for\\s*\\(|while\\s*\\(|return\\(|\\{\\s*$",
      trimmed
    )

    if (!in_code) {
      if (is_code_like && !grepl("^\\s*[A-Za-z ,?]+$", trimmed)) {
        # Single line of code — check if it's complete
        if (grepl("\\{\\s*$", trimmed) || grepl("\\)\\s*\\{\\s*$", trimmed)) {
          # Multi-line code starts
          in_code <- TRUE
          buffer <- trimmed
          next
        }
        # Single-line code
        set_code(trimmed)
        cat("Analyzing...\n\n")
        result <- agent$invoke(paste0("Review this R code:\n", trimmed))
        cat(result, "\n\n")
        next
      }
      # Regular question
      if (nchar(trimmed) == 0) next
      code <- get_code()
      msg <- if (nzchar(code))
        paste0(trimmed, "\n\n[Code under review:\n", code, "\n]")
      else
        trimmed
      cat("Thinking...\n\n")
      result <- agent$invoke(msg)
      cat(result, "\n\n")
      next
    }

    # In code mode — accumulate lines
    buffer <- c(buffer, line)
  }

  cat("\nGoodbye.\n")
}

main()
