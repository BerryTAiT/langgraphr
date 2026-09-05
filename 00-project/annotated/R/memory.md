# langgraphr/R/memory.R

<!-- TARGET: langgraphr/R/memory.R -->

> Memory helpers. Memory = LangGraph checkpoints keyed by thread id.
> Default is in-process memory; `lg_use_sqlite()` switches the hidden server
> to a durable SQLite checkpointer (server restart required).

```r
# memory.R - conversation memory configuration and inspection.
#
# Rule of thumb: reuse a thread id and the agent/graph remembers everything
# from earlier runs on that thread. Threads live on the server's checkpointer:
#   - in-process (MemorySaver)  -> lost when the server stops
#   - sqlite (LANGGRAPHR_DB)    -> survives restarts (durable)

# lg_use_sqlite tells the hidden server to persist checkpoints to a SQLite
# database at db_path. It takes effect the next time the server starts.
lg_use_sqlite <- function(db_path) {
  # The path must be a non-empty string.
  if (!is.character(db_path) || length(db_path) != 1L || !nzchar(db_path)) {
    cli::cli_abort("db_path must be a single non-empty file path")
  }
  # The path is relative to the current working directory by default;
  # converting to an absolute path avoids surprises after setwd().
  db_path <- normalizePath(db_path, winslash = "/", mustWork = FALSE)
  # Store the path in the LANGGRAPHR_DB environment variable. The server
  # reads this variable when it boots (see runtime.py on the Python side).
  Sys.setenv(LANGGRAPHR_DB = db_path)
  # Tell the user what happened and that a restart is needed.
  cli::cli_alert_info(paste0(
    "SQLite memory enabled at ", db_path,
    ". Restart the server (lg_stop_server(); lg_connect()) to apply."
  ))
  # Return the resolved path invisibly.
  invisible(db_path)
}

# lg_threads lists the thread ids the server currently knows about.
# This is a helper for maintainers and debugging; normal code just reuses
# thread ids it already has.
lg_threads <- function(port = getOption("langgraphr.port", 8123L)) {
  # Ask the server for every thread id it has seen.
  out <- .lg_get(port, "/threads")
  # Return the list of thread ids (a character vector).
  out$threads %||% character(0)
}

# lg_thread_id is defined in client.R (it is the same generator used by
# agents and graphs). This alias documents the connection to memory:
# a "thread" IS the unit of memory in langgraphr.
lg_new_thread <- function() {
  # Generate and return a brand-new thread id.
  lg_thread_id()
}
```
