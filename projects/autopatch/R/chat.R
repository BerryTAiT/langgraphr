# chat.R - interactive chat mode for AutoPatch.
# Lets the user talk to AutoPatch about their codebase: ask about past patch
# runs, read reports, list files, scan for defects, and view diffs between
# original and patched files. Built on the langgraphr ASSISTANT path
# (lg_connect() -> LgAgent), the same proven pattern as projects/r_chatbot.
#
# Run:  Rscript main.R            (chat is the default mode)
# Commands: code = paste multi-line R code for review (end with ###);
#           clear = reset the conversation;  quit / exit / q  to leave.

# AUTOPATCH_PERSONA - seeded as the first message of every conversation so
# the instruction sits at the top of the remembered history.
AUTOPATCH_PERSONA <- paste0(
  "You are AutoPatch, the Enterprise Autonomous Modernization & Patching ",
  "Engine, in interactive chat mode. The flow is: WAIT for the user's code ",
  "or question first, then review it - never start working unprompted and ",
  "never ask yes/no approval questions; just answer and wait for the next ",
  "message. When the user pastes code or names a file, review it: concrete ",
  "defects (hardcoded secrets, eval(parse()), .Internal(), fragile 1:n, ",
  "= assignment, T/F globals, sapply, paste sep) with file, line and ",
  "severity, plus suggested fixes. You have tools to list patch runs, read ",
  "run reports, list repo files, read files, scan files or the whole repo ",
  "for defects, and show diffs between original and patched files. Be ",
  "concise and specific: cite file, line, and defect id when reporting ",
  "findings. When showing code diffs, emit fenced code blocks tagged with ",
  "the diff language so additions and deletions render colored. If the ",
  "user wants the repo actually patched, explain that the ",
  "patch pipeline (with its own human approval gate) is launched ",
  "separately via 'Rscript main.R --run', and offer to scan first."
)

# ---- Tools (plain R functions; return JSON-safe text, never data frames) ----

# ap_resolve - find a repo file for the LLM. The model tends to send bare
# filenames ("secrets.R"), R/-relative paths ("R/secrets.R"), or paths that
# already carry the repo folder name ("sample_repo/R/secrets.R"). Accept
# all of them: absolute paths pass through, everything else is tried
# against the repo root and the repo's R/ directory.
ap_resolve <- function(path) {
  root <- getOption("autopatch.chat_repo", ".")
  if (grepl("^[A-Za-z]:", path) || startsWith(path, "/")) return(path)
  rel <- path
  rb <- basename(normalizePath(root, winslash = "/"))
  if (startsWith(rel, paste0(rb, "/")) || startsWith(rel, paste0(rb, "\\"))) {
    rel <- sub("^[^/\\\\]+[\\\\/]", "", rel)
  }
  cnd <- c(file.path(root, rel), file.path(root, "R", rel))
  hit <- cnd[file.exists(cnd)]
  if (length(hit) >= 1L) hit[[1]] else cnd[[1]]
}

# ap_list_runs - list completed patch runs (PR bundles) with timestamps.
ap_list_runs <- function() {
  root <- getOption("autopatch.chat_patches", "patches")
  if (!dir.exists(root)) return(sprintf("No patches directory at %s yet.", root))
  dirs <- sort(list.dirs(root, recursive = FALSE, full.names = FALSE),
               decreasing = TRUE)
  if (length(dirs) == 0) return("No patch runs yet.")
  lines <- vapply(dirs, function(d) {
    p <- file.path(root, d)
    info <- file.info(p)
    mtime <- if (is.na(info$mtime)) "?" else format(info$mtime, "%Y-%m-%d %H:%M:%S")
    rf <- sort(list.files(file.path(p, "R"), pattern = "\\.R$"))
    sprintf("- %s (%s): %s", d, mtime, paste(rf, collapse = ", "))
  }, character(1))
  paste(c(sprintf("%d run(s):", length(dirs)), lines), collapse = "\n")
}

# ap_run_report - read the report + PR description of a run (default latest).
ap_run_report <- function(run_id = NULL) {
  root <- getOption("autopatch.chat_patches", "patches")
  if (!dir.exists(root)) return("No patches directory yet.")
  if (is.null(run_id) || !nzchar(run_id)) {
    dirs <- sort(list.dirs(root, recursive = FALSE, full.names = FALSE),
                 decreasing = TRUE)
    if (length(dirs) == 0) return("No patch runs yet.")
    run_id <- dirs[[1]]
  }
  p <- file.path(root, run_id)
  if (!dir.exists(p)) return(sprintf("No such run: %s", run_id))
  parts <- list()
  for (f in c("report.md", "PR_DESCRIPTION.md")) {
    fp <- file.path(p, f)
    if (file.exists(fp)) {
      parts[[f]] <- paste(readLines(fp, warn = FALSE), collapse = "\n")
    }
  }
  if (length(parts) == 0) return(sprintf("Run %s has no report files.", run_id))
  paste(vapply(names(parts), function(n) {
    sprintf("=== %s ===\n%s", n, parts[[n]])
  }, character(1)), collapse = "\n\n")
}

# ap_list_repo_files - list R source files in the target repo with line counts.
ap_list_repo_files <- function() {
  root <- getOption("autopatch.chat_repo", ".")
  rdir <- file.path(root, "R")
  if (!dir.exists(rdir)) rdir <- root
  files <- sort(list.files(rdir, pattern = "\\.R$", full.names = TRUE))
  if (length(files) == 0) return(sprintf("No .R files under %s", rdir))
  lines <- vapply(files, function(f) {
    n <- length(readLines(f, warn = FALSE))
    sprintf("- %s (%d lines)", basename(f), n)
  }, character(1))
  paste(c(sprintf("Repo: %s (%d file(s))", root, length(files)), lines),
        collapse = "\n")
}

# ap_read_file - read the full text of one file (bare filename,
# repo-relative, or absolute path; resolved via ap_resolve).
ap_read_file <- function(path) {
  p <- ap_resolve(path)
  if (!file.exists(p)) return(sprintf("File not found: %s", path))
  info <- file.info(p)
  if (!is.na(info$size) && info$size > 200000) {
    return(sprintf("File too large to inline (%d bytes).", info$size))
  }
  paste(readLines(p, warn = FALSE), collapse = "\n")
}

# ap_scan_file - scan one R file for defects and list the findings.
ap_scan_file <- function(path) {
  p <- ap_resolve(path)
  if (!file.exists(p)) return(sprintf("File not found: %s", path))
  dl <- scan_defects(paste(readLines(p, warn = FALSE), collapse = "\n"))
  if (length(dl) == 0) return(sprintf("%s: no defects detected.", basename(p)))
  lines <- vapply(dl, function(d) {
    sprintf("- [%s] %s (line %s): %s", d$severity, d$id, d$line, d$desc)
  }, character(1))
  paste(c(sprintf("%s: %d defect(s)", basename(p), length(dl)), lines),
        collapse = "\n")
}

# ap_scan_repo - scan every R file in the repo and return per-file counts.
ap_scan_repo <- function() {
  root <- getOption("autopatch.chat_repo", ".")
  rdir <- file.path(root, "R")
  if (!dir.exists(rdir)) rdir <- root
  files <- sort(list.files(rdir, pattern = "\\.R$", full.names = TRUE))
  if (length(files) == 0) return(sprintf("No .R files under %s", rdir))
  per <- vapply(files, function(f) {
    length(scan_defects(paste(readLines(f, warn = FALSE), collapse = "\n")))
  }, integer(1))
  lines <- vapply(seq_along(files), function(i) {
    sprintf("- %s: %d", basename(files[[i]]), per[[i]])
  }, character(1))
  paste(c(sprintf("Scanned %d file(s), %d total defect(s):",
                  length(files), sum(per)), lines), collapse = "\n")
}

# ap_read_diff - diff an original repo file against its patched version.
ap_read_diff <- function(run_id = NULL, file = NULL) {
  root <- getOption("autopatch.chat_patches", "patches")
  repo <- getOption("autopatch.chat_repo", ".")
  if (!dir.exists(root)) return("No patches directory yet.")
  if (is.null(run_id) || !nzchar(run_id)) {
    dirs <- sort(list.dirs(root, recursive = FALSE, full.names = FALSE),
                 decreasing = TRUE)
    if (length(dirs) == 0) return("No patch runs yet.")
    run_id <- dirs[[1]]
  }
  pdir <- file.path(root, run_id, "R")
  if (!dir.exists(pdir)) return(sprintf("Run %s has no patched R/ directory.", run_id))
  files <- sort(list.files(pdir, pattern = "\\.R$", full.names = TRUE))
  if (!is.null(file) && nzchar(file)) {
    files <- files[grepl(file, basename(files), fixed = TRUE)]
  }
  if (length(files) == 0) return(sprintf("No patched files in run %s.", run_id))
  parts <- vapply(files, function(pf) {
    orig <- file.path(repo, "R", basename(pf))
    new_txt <- readLines(pf, warn = FALSE)
    old_txt <- if (file.exists(orig)) readLines(orig, warn = FALSE) else character(0)
    d <- paste(lcs_diff(old_txt, new_txt), collapse = "\n")
    sprintf("=== %s ===\n%s", basename(pf), if (nzchar(d)) d else "(identical)")
  }, character(1))
  paste(parts, collapse = "\n\n")
}

# ap_register_tools - single source of truth for the toolset. Used by the
# console agent (build_chat_agent) and the background worker (ap_chat_turn)
# so the two front ends can never drift apart.
ap_register_tools <- function(agent) {
  agent$add_tool(ap_list_runs,
    description = "List completed patch runs (PR bundles) with timestamps and patched files.")
  agent$add_tool(ap_run_report,
    description = "Read the report.md and PR_DESCRIPTION.md of a patch run (defaults to the latest run).")
  agent$add_tool(ap_list_repo_files,
    description = "List the R source files in the target repo with line counts.")
  agent$add_tool(ap_read_file,
    description = "Read the full text of a file in the target repo (repo-relative or absolute path).")
  agent$add_tool(ap_scan_file,
    description = "Scan one R file for code defects and return the list of findings.")
  agent$add_tool(ap_scan_repo,
    description = "Scan every R file in the repo and return per-file defect counts.")
  agent$add_tool(ap_read_diff,
    description = "Show the line diff between an original repo file and its patched version from a run.")
}

# build_chat_agent - console path: connect, register tools, seed persona.
build_chat_agent <- function(repo, patches_root) {
  options(autopatch.chat_repo = repo, autopatch.chat_patches = patches_root)
  agent <- lg_connect()
  ap_register_tools(agent)
  seed_chat_agent(agent)
  agent
}

# ap_chat_turn - one full conversation turn, SELF-CONTAINED so it can run
# in a BACKGROUND R process (how app.R keeps the UI responsive while the
# model works). callr workers get a fresh global environment: functions
# referenced across sourced files do NOT survive serialization
# (probe-verified 2026-09-10: "could not find function ..."), so the
# worker re-sources the modules it needs before wiring the agent.
ap_chat_turn <- function(msg, thread_id, seed = NULL, repo, patches_root,
                         env_path = NULL, script_dir = NULL, db_path = NULL) {
  library(langgraphr)
  if (!is.null(env_path) && file.exists(env_path)) {
    try(dotenv::load_dot_env(env_path), silent = TRUE)
  }
  # Re-source: gives the worker its own definitions of the tool functions
  # and their cross-file dependencies (scan_defects, lcs_diff, ...).
  for (f in c("defects.R", "test_runner.R", "chat.R")) {
    source(file.path(script_dir, "R", f))
  }
  options(autopatch.chat_repo = repo, autopatch.chat_patches = patches_root)
  if (!is.null(db_path)) lg_use_sqlite(db_path)
  # Reconnect to the SAME thread: the server restores this conversation.
  agent <- lg_connect(thread_id = thread_id)
  ap_register_tools(agent)
  # Fresh thread: seed the persona first (same idea as seed_chat_agent).
  if (!is.null(seed) && nzchar(seed)) {
    invisible(agent$invoke(paste0("System note: ", seed,
                                  "\nAcknowledge with exactly: Ready.")))
  }
  res <- agent$invoke(msg)
  list(content = if (is.null(res$content)) "(no reply)" else res$content,
       thread_id = agent$thread_id)
}

# seed_chat_agent - inject the persona as the first message of the thread.
seed_chat_agent <- function(agent) {
  invisible(agent$invoke(paste0("System note: ", AUTOPATCH_PERSONA,
                                "\nAcknowledge with exactly: Ready.")))
}

# run_chat - the console conversation loop.
# Interactive R sessions only: under Rscript on Windows, R's stdin is wired
# to the script's own execution stream (a probe showed readLines(stdin())
# returning the script's remaining lines and readline() returning ""
# forever), so console input is unreachable there. We detect that, tell
# the user how to launch properly, and exit instead of hanging.
run_chat <- function(agent) {
  if (!interactive()) {
    cat("AutoPatch chat needs an interactive R session (console input is\n")
    cat("not reachable under Rscript on Windows).\n")
    cat("  RStudio : open projects/autopatch/main.R and press Source\n")
    cat("  or in R : source('projects/autopatch/main.R')\n")
    cat("The patch pipeline is unaffected: Rscript main.R --run --yes\n")
    return(invisible(agent))
  }
  cat("AutoPatch chat. Bring your R code or a question - I'll wait.\n")
  cat("Commands: code = paste multi-line R code for review | clear | quit\n\n")
  repeat {
    msg <- trimws(readline("You: "))
    if (!nzchar(msg)) next
    if (tolower(msg) %in% c("quit", "exit", "q")) { cat("Goodbye!\n"); break }
    if (tolower(msg) == "clear") {
      agent$reset(); seed_chat_agent(agent)
      cat("(memory cleared - fresh conversation)\n")
      next
    }
    if (tolower(msg) == "code") {
      cat("Paste your R code. Finish with a line containing only: ###\n")
      lines <- character(0)
      repeat {
        l <- readline()
        if (identical(trimws(l), "###")) break
        lines <- c(lines, l)
      }
      if (length(lines) == 0) { cat("(nothing pasted)\n\n"); next }
      msg <- paste0(
        "Review this R code. List the concrete problems (security, ",
        "correctness, style) with line numbers, then suggest fixes:\n\n",
        paste(lines, collapse = "\n"))
    }
    cat("AutoPatch: ...\n")
    res <- tryCatch(agent$invoke(msg), error = function(e) e)
    if (inherits(res, "error")) {
      cat("Error:", conditionMessage(res), "\n\n")
      next
    }
    cat("\nAutoPatch:", res$content %||% "(no reply)", "\n\n")
  }
  invisible(agent)
}
