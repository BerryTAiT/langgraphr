# graph.R - the two langgraphr graphs of AutoPatch.
#
# WORKER SUBGRAPH  ("autopatch_worker"): the per-file Refactor -> Test ->
#   Self-Correction loop. Entry: refactor. The test node routes back to
#   refactor (a cycle) with the captured stderr until tests pass or attempts
#   are exhausted; the final fallback is the deterministic rule fixer.
#
# ORCHESTRATOR ("autopatch"): scanner -> dispatch (self-cycle; invokes one
#   worker run per file - sequential map-reduce until the package gains
#   parallel Send support) -> gate (human-in-the-loop interrupt pause) ->
#   pr (writes the patch bundle). The `fixes` channel uses the append
#   reducer so worker results aggregate without overwriting.

ap_opt <- function(name, default) getOption(paste0("autopatch.", name), default)
ap_json <- function(x) jsonlite::toJSON(x, auto_unbox = TRUE)
ap_from_json <- function(s) {
  if (is.null(s) || !nzchar(s)) list() else jsonlite::fromJSON(s, simplifyVector = FALSE)
}

# ---------------------------------------------------------------------------
# Worker subgraph
# ---------------------------------------------------------------------------
build_worker <- function() {
  b <- lg_graph("autopatch_worker", state = list(
    content       = list(type = "str"),
    defects       = list(type = "str"),
    fixed_content = list(type = "str"),
    attempts      = list(type = "number"),
    error_log     = list(type = "str"),
    verdict       = list(type = "str"),
    fix_method    = list(type = "str"),
    diff          = list(type = "str")
  ))

  b <- lg_add_node(b, "refactor", function(state) {
    file <- state$input
    content <- state$content %||%
      paste(readLines(file, warn = FALSE), collapse = "\n")
    defects <- state$defects
    if (is.null(defects)) {
      dl <- scan_defects(content)
      defects <- ap_json(dl)
      cat(sprintf("    [worker] %s: %d defect(s) detected\n",
                  basename(file), length(dl)))
    }
    attempts <- (state$attempts %||% 0) + 1
    max_llm <- ap_opt("max_llm", 2)
    fixed <- NULL
    method <- "none"
    if (!ap_opt("no_llm", FALSE) && attempts <= max_llm) {
      cat(sprintf("    [worker] attempt %d (LLM)...\n", attempts))
      fixed <- llm_fix(content, defects,
                       prev = state$fixed_content,
                       error_log = state$error_log)
      method <- "llm"
    }
    if (is.null(fixed) || !validate_candidate(fixed)$ok) {
      if (!is.null(fixed)) cat("    [worker] LLM output invalid; applying rule-based fixes\n")
      fixed <- rule_fix(content)
      method <- "rules"
    }
    list(updates = list(
      content = content,
      defects = defects,
      attempts = attempts,
      fixed_content = fixed,
      fix_method = method
    ))
  })

  b <- lg_add_node(b, "test", function(state) {
    res <- run_tests(state$input, state$fixed_content)
    d <- paste(lcs_diff(content_lines(state$content),
                        content_lines(state$fixed_content)),
               collapse = "\n")
    if (res$ok) {
      cat(sprintf("    [worker] tests PASSED (via %s)\n", state$fix_method))
      return(list(updates = list(
        verdict = paste0("passed_", state$fix_method),
        diff = d
      ), goto = "__end__"))
    }
    total_max <- ap_opt("max_llm", 2) + 1L
    if ((state$attempts %||% 0) >= total_max) {
      cat("    [worker] tests FAILED after all attempts - giving up on this file\n")
      return(list(updates = list(
        verdict = "failed",
        diff = d,
        error_log = res$log
      ), goto = "__end__"))
    }
    cat("    [worker] tests FAILED - cycling back to refactor with error feedback\n")
    list(updates = list(error_log = res$log), goto = "refactor")
  })

  b <- lg_add_edge(b, "refactor", "test")
  b
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------
build_orchestrator <- function(worker) {
  b <- lg_graph("autopatch", state = list(
    repo_path     = list(type = "str"),
    queue         = list(type = "list"),
    total_files   = list(type = "number"),
    done_files    = list(type = "number"),
    fixes         = list(type = "list", reducer = "append"),
    gate_decision = list(type = "str"),
    pr_dir        = list(type = "str"),
    summary       = list(type = "str")
  ))

  b <- lg_add_node(b, "scanner", function(state) {
    repo <- normalizePath(state$input, winslash = "/")
    cat(sprintf("\n[scanner] scanning %s ...\n", repo))
    files <- sort(list.files(file.path(repo, "R"), pattern = "[.]R$",
                             full.names = TRUE))
    if (length(files) == 0L) {
      cat("[scanner] no R files found under R/\n")
      return(list(updates = list(repo_path = repo, total_files = 0,
                                 done_files = 0)))
    }
    queue <- character(0)
    for (f in files) {
      content <- paste(readLines(f, warn = FALSE), collapse = "\n")
      dl <- scan_defects(content)
      crit <- length(Filter(function(d) identical(d$severity, "critical"), dl))
      if (length(dl) > 0) {
        queue <- c(queue, f)
        cat(sprintf("  %-18s %d defect(s) (%d critical)\n",
                    basename(f), length(dl), crit))
      } else {
        cat(sprintf("  %-18s clean\n", basename(f)))
      }
    }
    cat(sprintf("[scanner] %d of %d file(s) need patching\n",
                length(queue), length(files)))
    upd <- list(repo_path = repo, total_files = length(queue), done_files = 0)
    if (length(queue) > 0) upd$queue <- as.list(queue)
    list(updates = upd)
  })

  b <- lg_add_node(b, "dispatch", function(state) {
    done <- state$done_files %||% 0
    total <- state$total_files %||% 0
    q <- state$queue
    if (is.null(q) || length(q) == 0 || done >= total) {
      return(list(goto = "gate"))
    }
    i <- done + 1L
    file <- q[[i]]
    if (is.list(file)) file <- file[[1]]
    cat(sprintf("\n== [%d/%d] %s ==\n", i, total, basename(file)))

    wres <- tryCatch(
      worker$invoke(
        file,
        # Unique per run: reused thread ids would inherit stale worker
        # state (content, attempts) from earlier runs on the same file.
        thread_id = paste0("apw_", ap_opt("run_stamp", "run"), "_", i, "_",
                           gsub("[^A-Za-z0-9]", "", basename(file)))
      ),
      error = function(e) e
    )
    if (inherits(wres, "error")) {
      rec <- ap_json(list(
        file = basename(file), status = "error", attempts = 0,
        method = "none", error = conditionMessage(wres),
        diff = "", fixed = "", defects = "[]"
      ))
    } else {
      ws <- wres$state
      rec <- ap_json(list(
        file = basename(file),
        status = ws$verdict %||% "unknown",
        attempts = as.integer(ws$attempts %||% 0),
        method = ws$fix_method %||% "",
        error = ws$error_log %||% "",
        diff = ws$diff %||% "",
        fixed = ws$fixed_content %||% "",
        defects = ws$defects %||% "[]"
      ))
    }
    list(updates = list(fixes = rec, done_files = i), goto = "dispatch")
  })

  b <- lg_add_node(b, "gate", function(state) {
    recs <- state$fixes
    if (is.null(recs) || length(recs) == 0) {
      cat("\n[gate] no defects were found - nothing to review\n")
      return(list(updates = list(
        gate_decision = "approved",
        summary = "No defects found; no patches needed."
      ), goto = "pr"))
    }
    cat("\n================ HUMAN REVIEW GATE ================\n")
    cat("The run is paused inside the graph (interrupt). Review the diffs:\n")
    for (r in recs) {
      d <- ap_from_json(r)
      cat(sprintf("\n--- %s  [%s | attempts: %s | via %s] ---\n",
                  d$file, d$status, d$attempts, d$method))
      dd <- d$diff %||% ""
      cat(if (nzchar(dd)) dd else "(no changes)", sep = "\n")
    }
    cat("\n===================================================\n")
    park <- ap_opt("park_until", NULL)
    if (!is.null(park)) {
      cat(sprintf("[gate] PARKED - waiting for decision file: %s\n", park))
      while (!file.exists(park)) Sys.sleep(0.5)
      ans <- tolower(trimws(paste(readLines(park, warn = FALSE),
                                   collapse = "")))
      cat(sprintf("[gate] decision file says: '%s'\n", ans))
      dec <- if (ans %in% c("y", "yes", "approved", "approve")) "approved" else "rejected"
    } else if (ap_opt("yes", FALSE)) {
      cat("[gate] --yes flag set: auto-approving\n")
      dec <- "approved"
    } else {
      ans <- tolower(trimws(readline("\nApprove these patches and open the PR? [y/N]: ")))
      dec <- if (ans %in% c("y", "yes")) "approved" else "rejected"
    }
    cat(sprintf("[gate] decision: %s\n", dec))
    list(updates = list(gate_decision = dec))
  })

  b <- lg_add_node(b, "pr", function(state) {
    dec <- state$gate_decision %||% "rejected"
    recs <- state$fixes %||% character(0)
    if (!identical(dec, "approved") || length(recs) == 0) {
      s <- sprintf("Run finished: REJECTED by reviewer - %d file(s) fixed but no PR created.",
                   length(recs))
      cat("\n[pr]", s, "\n")
      return(list(updates = list(summary = s), goto = "__end__"))
    }
    stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
    pr_dir <- file.path(ap_opt("out_root", getwd()), paste0("PR_", stamp))
    dir.create(file.path(pr_dir, "R"), recursive = TRUE, showWarnings = FALSE)

    applied <- 0L
    rows <- character(0)
    report <- c("# AutoPatch Run Report", "",
                sprintf("- Repository: %s", state$repo_path),
                sprintf("- Generated: %s", format(Sys.time())),
                sprintf("- Gate decision: approved"), "")
    for (r in recs) {
      d <- ap_from_json(r)
      passed <- startsWith(as.character(d$status), "passed")
      if (passed) {
        writeLines(as.character(d$fixed), file.path(pr_dir, "R", as.character(d$file)))
        applied <- applied + 1L
      }
      rows <- c(rows, sprintf("| %s | %s | %s | %s |",
                              d$file, d$status, d$attempts, d$method))
      report <- c(report, sprintf("## %s\n\n- status: %s\n- attempts: %s (via %s)\n",
                                  d$file, d$status, d$attempts, d$method))
      dd <- d$diff %||% ""
      if (nzchar(dd)) report <- c(report, "```diff", dd, "```")
      er <- d$error %||% ""
      if (nzchar(er)) report <- c(report, "\nLast test output:\n```", er, "```")
      report <- c(report, "")
    }

    pr_desc <- c(
      "# AutoPatch Pull Request", "",
      sprintf("Automated modernization of `%s`.", state$repo_path), "",
      "| File | Status | Attempts | Method |", "|---|---|---|---|", rows, "",
      sprintf("**%d file(s) patched.** All patches passed the local test loop ",
              applied),
      "before human review; the reviewer approved this bundle.", "",
      "Generated by AutoPatch (langgraphr)."
    )
    writeLines(pr_desc, file.path(pr_dir, "PR_DESCRIPTION.md"))
    writeLines(report, file.path(pr_dir, "report.md"))

    s <- sprintf("Run finished: APPROVED - %d file(s) patched, PR bundle at %s",
                 applied, pr_dir)
    cat("\n[pr]", s, "\n")
    list(updates = list(pr_dir = pr_dir, summary = s), goto = "__end__")
  })

  b <- lg_add_edge(b, "scanner", "dispatch")
  b <- lg_add_edge(b, "dispatch", "gate")
  b <- lg_add_edge(b, "gate", "pr")
  b
}

# ---------------------------------------------------------------------------
# Run entry point
# ---------------------------------------------------------------------------
run_autopatch <- function(repo, thread_id = NULL) {
  options(autopatch.run_stamp = format(Sys.time(), "%Y%m%d_%H%M%S"))
  worker <- lg_compile(build_worker())
  orch <- lg_compile(build_orchestrator(worker))
  thread_id <- thread_id %||% paste0("autopatch_", ap_opt("run_stamp", "run"))
  cat(sprintf("[autopatch] thread: %s\n", thread_id))
  orch$invoke(repo, thread_id = thread_id, max_rounds = 200L)
}
