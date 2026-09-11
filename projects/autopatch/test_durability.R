# test_durability.R - prove durable checkpoints survive a crash+restart.
# Usage: Rscript test_durability.R <thread_id>
# Re-invokes the orchestrator on the SAME thread; if the sqlite checkpoints
# survived, the `fixes` append channel still holds the records from the
# crashed run, so the gate shows old + new records.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: Rscript test_durability.R <thread_id>")
tid <- args[[1]]

script_dir <- "C:/Users/berry/Desktop/creatingWrapper For LangGraph/projects/autopatch"
suppressPackageStartupMessages(library(langgraphr))
for (f in c("env.R", "defects.R", "fixer.R", "llm_refactor.R",
            "test_runner.R", "graph.R")) {
  source(file.path(script_dir, "R", f), local = FALSE)
}
options(autopatch.yes = TRUE, autopatch.no_llm = TRUE,
        autopatch.out_root = file.path(script_dir, "patches"))
options(autopatch.run_stamp = format(Sys.time(), "%Y%m%d_%H%M%S"))

lg_use_sqlite(file.path(script_dir, "autopatch.db"))

worker <- lg_compile(build_worker())
orch <- lg_compile(build_orchestrator(worker))
cat(sprintf("[durability] re-invoking orchestrator on crashed thread: %s\n", tid))
res <- orch$invoke(file.path(script_dir, "sample_repo"),
                   thread_id = tid, max_rounds = 200L)
cat("\n[durability] final status:", res$status, "\n")
cat("[durability] summary:", res$state$summary %||% "(none)", "\n")
