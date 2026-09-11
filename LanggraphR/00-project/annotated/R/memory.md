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

#' Persist conversation memory to SQLite
#'
#' Sets `LANGGRAPHR_DB` so the hidden server checkpoints threads to a SQLite
#' file instead of in-memory storage, making conversations survive server
#' restarts. Takes effect the next time the server starts.
#'
#' @param db_path Path to the SQLite database file.
#' @return The resolved path, invisibly.
#' @export
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

#' List known thread ids
#'
#' Lists every thread id the running server has seen. Useful for debugging
#' and maintenance; normal code reuses thread ids it already has.
#'
#' @param port Port of the running server.
#' @return A character vector of thread ids.
#' @export
lg_threads <- function(port = getOption("langgraphr.port", 8123L)) {
  # Ask the server for every thread id it has seen.
  out <- .lg_get(port, "/threads")
  # Return the list of thread ids (a character vector).
  out$threads %||% character(0)
}

#' Generate a fresh thread id (alias of [lg_thread_id])
#'
#' A "thread" is the unit of memory in langgraphr. This alias makes the
#' memory semantics explicit in code: starting a new thread means starting
#' a fresh conversation.
#'
#' @return A new unique thread id.
#' @export
lg_new_thread <- function() {
  # Generate and return a brand-new thread id.
  lg_thread_id()
}
```
