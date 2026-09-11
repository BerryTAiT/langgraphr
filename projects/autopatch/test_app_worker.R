# test_app_worker.R - E2E proof of the app's background-worker path.
# Replicates EXACTLY what app.R does: run ap_chat_turn (self-contained)
# inside a callr::r_bg worker with a fresh seeded thread, then a second
# turn on the same thread to prove memory works across workers.
suppressPackageStartupMessages({
  library(callr)
  library(langgraphr)
})
source("projects/autopatch/R/chat.R")

script_dir <- normalizePath("projects/autopatch", winslash = "/")
tid <- lg_thread_id()
cat("[test] fresh thread:", tid, "\n")

run_turn <- function(msg, seed = NULL, thread_id) {
  job <- callr::r_bg(ap_chat_turn, list(
    msg = msg,
    thread_id = thread_id,
    seed = seed,
    repo = file.path(script_dir, "sample_repo"),
    patches_root = file.path(script_dir, "patches"),
    env_path = file.path(script_dir, ".env"),
    script_dir = script_dir,
    db_path = file.path(script_dir, "autopatch.db")
  ))
  repeat {
    if (!job$is_alive()) break
    Sys.sleep(0.5)
  }
  job$get_result()
}

cat("\n[turn 1] seeding + tool-using question...\n")
r1 <- run_turn(
  "Scan the sample repo and give me per-file defect counts, ordered by severity.",
  seed = AUTOPATCH_PERSONA,
  thread_id = tid
)
cat("[turn 1] reply:\n", r1$content, "\n\n")
cat("[turn 1] thread:", r1$thread_id, "\n")

cat("[turn 2] follow-up on the SAME thread (memory across workers)...\n")
r2 <- run_turn(
  "Which of those files is the most dangerous, and what was my previous question?",
  seed = NULL,
  thread_id = r1$thread_id
)
cat("[turn 2] reply:\n", r2$content, "\n")

stopifnot(grepl("secrets\\.R", r1$content, ignore.case = TRUE))
cat("\n[TEST PASSED] worker turn + tool call + cross-worker memory OK\n")
