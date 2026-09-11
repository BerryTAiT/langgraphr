# main.R - AutoPatch console entry point.
# Enterprise Autonomous Modernization & Patching Engine, built on langgraphr.
#
# Run:
#   CHAT (default) - needs an interactive R session; waits for your code:
#     source("projects/autopatch/main.R")     # R console / RStudio Source
#   PIPELINE - works under Rscript:
#     Rscript main.R --run                    # y/N gate at the end
#     Rscript main.R --run --yes              # auto-approve the gate
#     Rscript main.R --run --no-llm --yes     # deterministic rules only
#     Rscript main.R --run --repo C:/path --yes
#     Rscript main.R --run --stress --yes     # strict tests (forces retries)
#     Rscript main.R --run --no-llm --park D:/d.txt  # park at gate until file appears
#     Rscript main.R --resume <thread_id>     # crash-recovery probe
#
# Under Rscript with no flags you get chat-mode guidance (console input is
# unreachable there); use source() for the actual conversation.

# ---- Parse CLI arguments -------------------------------------------------
cli_args <- commandArgs(trailingOnly = TRUE)
opt <- list(repo = NULL, yes = FALSE, stress = FALSE, no_llm = FALSE,
            max_llm = 2L, memory = NULL, resume = NULL, park = NULL,
            chat = FALSE, run = FALSE)
k <- 1L
while (k <= length(cli_args)) {
  a <- cli_args[[k]]
  if (a == "--repo") { opt$repo <- cli_args[[k + 1L]]; k <- k + 1L }
  else if (a == "--yes") opt$yes <- TRUE
  else if (a == "--stress") opt$stress <- TRUE
  else if (a == "--no-llm") opt$no_llm <- TRUE
  else if (a == "--max-llm") { opt$max_llm <- as.integer(cli_args[[k + 1L]]); k <- k + 1L }
  else if (a == "--memory") { opt$memory <- cli_args[[k + 1L]]; k <- k + 1L }
  else if (a == "--resume") { opt$resume <- cli_args[[k + 1L]]; k <- k + 1L }
  else if (a == "--park") { opt$park <- cli_args[[k + 1L]]; k <- k + 1L }
  else if (a == "--chat") opt$chat <- TRUE
  else if (a == "--run") opt$run <- TRUE
  k <- k + 1L
}

# ---- Locate project + load modules --------------------------------------
# Bootstrap: find this script's directory (inline, before env.R is sourced).
# Every candidate is verified to actually contain R/graph.R.
script_dir <- local({
  has_graph <- function(d) file.exists(file.path(d, "R", "graph.R"))
  ca <- commandArgs(FALSE)
  f <- grep("^--file=", ca, value = TRUE)
  if (length(f) == 1L) {
    d <- dirname(normalizePath(sub("^--file=", "", f), winslash = "/"))
    if (has_graph(d)) return(d)
  }
  frame_files <- lapply(sys.frames(), function(fr) fr$ofile)
  nn <- which(!sapply(frame_files, is.null))
  for (i in nn) {
    d <- dirname(normalizePath(frame_files[[i]], winslash = "/"))
    if (has_graph(d)) return(d)
  }
  for (c in c("projects/autopatch", "autopatch", ".")) {
    if (has_graph(c)) return(normalizePath(c, winslash = "/"))
  }
  normalizePath(".", winslash = "/")
})

for (f in c("env.R", "defects.R", "fixer.R", "llm_refactor.R",
            "test_runner.R", "graph.R")) {
  source(file.path(script_dir, "R", f), local = FALSE)
}
ap_load_env(script_dir)

if (!requireNamespace("langgraphr", quietly = TRUE)) {
  stop("langgraphr not found. Run: install.packages('LanggraphR', repos = NULL, type = 'source')")
}
suppressPackageStartupMessages(library(langgraphr))

options(
  autopatch.yes = opt$yes,
  autopatch.stress = opt$stress,
  autopatch.no_llm = opt$no_llm,
  autopatch.max_llm = opt$max_llm,
  autopatch.park_until = opt$park,
  autopatch.out_root = file.path(script_dir, "patches")
)

# ---- Crash-recovery probe (documents the thread-resume gap) --------------
if (!is.null(opt$resume)) {
  cat("\n[resume] attempting to resume parked thread:", opt$resume, "\n")
  lg_connect()
  lg_compile(build_worker())
  lg_compile(build_orchestrator(NULL))
  perform <- getFromNamespace(".lg_perform", "langgraphr")
  port <- getOption("langgraphr.port", 8123L)
  res <- tryCatch(
    perform(port, paste0("/threads/", opt$resume, "/resume"),
            list(value = list(reply = list(
              goto = "pr", updates = list(gate_decision = "approved"))))),
    error = function(e) conditionMessage(e)
  )
  cat("[resume] server says:", res, "\n")
  if (is.character(res) && grepl("404|unknown thread", res)) {
    cat("\nGAP CONFIRMED: durable checkpoints survive the crash, but the
server forgets thread ownership on restart (in-memory _thread_kind map in
app.py). Package fix needed: persist thread kind with the checkpointer and
expose a client-side resume API.\n")
  }
  quit(save = "no", status = 0)
}

# ---- Configure durable memory BEFORE the server boots --------------------
db <- opt$memory %||% file.path(script_dir, "autopatch.db")
lg_use_sqlite(db)

# ---- Run -----------------------------------------------------------------
repo <- opt$repo %||% file.path(script_dir, "sample_repo")
if (!dir.exists(repo)) stop("repo not found: ", repo)

# ---- Mode selection ------------------------------------------------------
# Chat is the DEFAULT: AutoPatch waits for the user's code and questions,
# reviews what it is given, and never asks yes/no on its own. The patch
# pipeline (scan -> patch -> test -> human gate -> PR) runs only when
# explicitly asked for: --run, or any pipeline-only flag (--yes, --no-llm,
# --stress, --park, --memory).
want_pipeline <- opt$run || opt$yes || opt$no_llm || opt$stress ||
  !is.null(opt$park) || !is.null(opt$memory)
if (opt$chat || !want_pipeline) {
  source(file.path(script_dir, "R", "chat.R"))
  agent <- build_chat_agent(repo = repo,
                            patches_root = file.path(script_dir, "patches"))
  run_chat(agent)
  # Interactive session (source()): keep the user's R session alive; just
  # end the script here. Under Rscript there is no console input anyway
  # (run_chat says so), so exiting is correct.
  if (!interactive()) quit(save = "no", status = 0)
} else {
  cat("=== AutoPatch - Autonomous Modernization & Patching Engine ===\n")
  cat(sprintf("mode: %s | stress tests: %s | gate: %s\n",
              if (opt$no_llm) "rules-only" else sprintf("LLM(max %d) + rules fallback", opt$max_llm),
              if (opt$stress) "ON" else "off",
              if (opt$yes) "auto-approve" else "interactive"))

  res <- run_autopatch(repo)

  cat("\n================ AUTOPATCH SUMMARY ================\n")
  cat(res$state$summary %||% "(no summary)", "\n")
  if (!is.null(res$state$pr_dir) && nzchar(res$state$pr_dir)) {
    cat("PR bundle:", res$state$pr_dir, "\n")
  }
  cat("===================================================\n")
}
