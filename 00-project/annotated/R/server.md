# langgraphr/R/server.R

<!-- TARGET: langgraphr/R/server.R -->

> Lifecycle of the hidden server: python discovery, spawn via processx,
> health polling, stop. Users only call lg_start_server/lg_stop_server.

```r
# server.R - start/stop the hidden LangGraph server process.
#
# The server is a FastAPI app (Python) that lives in inst/server of the
# package. From R's point of view it is just a background process that
# answers HTTP on 127.0.0.1:8123. We spawn it, wait until it is healthy,
# and stop it when the session ends.

# ---- Python discovery ------------------------------------------------------
# .lg_python_candidates lists candidate interpreters in priority order.
# server_dir lets us prefer the project's own venv (created by the setup
# script) so installed dependencies are actually used.
.lg_python_candidates <- function(server_dir = NULL) {
  # Priority: 1) explicit option, 2) env var, 3) project venv python,
  #            4) uv command, 5) plain python commands.
  c(getOption("langgraphr.python"),                       # user option
    Sys.getenv("LANGGRAPHR_PYTHON", unset = NA_character_), # env override
    .lg_venv_python(server_dir),                          # bundled venv
    "uv", "python3", "python")                            # fallbacks
}

# .lg_venv_python returns the path of the python inside the project venv,
# or NA when no venv exists yet. Windows uses Scripts/, Unix uses bin/.
.lg_venv_python <- function(server_dir = NULL) {
  # Without a server directory there is nothing to look for.
  if (is.null(server_dir)) return(NA_character_)
  # Path of the python executable on Windows.
  win <- file.path(server_dir, ".venv", "Scripts", "python.exe")
  # Path of the python executable on macOS/Linux.
  unix <- file.path(server_dir, ".venv", "bin", "python")
  # Return whichever one actually exists on disk.
  if (file.exists(win)) return(win)
  if (file.exists(unix)) return(unix)
  # No venv found, so report NA (caller will try other candidates).
  NA_character_
}

# .lg_resolve_python picks the first working interpreter from the list.
.lg_resolve_python <- function(server_dir = NULL) {
  # Loop over every candidate in priority order.
  for (cand in .lg_python_candidates(server_dir)) {
    # Skip missing or empty candidates (e.g. unset env vars).
    if (is.na(cand) || !nzchar(cand)) next
    # If the candidate is a real file path, use it directly (venv python).
    # normalizePath() converts relative paths (e.g. from options()) into
    # absolute ones, which processx requires when spawning the process.
    if (file.exists(cand)) {
      return(normalizePath(cand, winslash = "/", mustWork = TRUE))
    }
    # Otherwise treat it as a command name and find it on the PATH.
    hit <- Sys.which(cand)
    # If the command exists on the PATH, use its full path.
    if (nzchar(hit)) return(hit)
  }
  # None of the candidates worked: abort with setup instructions.
  cli::cli_abort(c(
    "No Python interpreter found.",
    "i" = "Install Python >= 3.10 or `uv`, or run scripts/setup_server.ps1."
  ))
}

# ---- Locating the server bundle ---------------------------------------------
# .lg_server_dir returns the folder that contains the Python server files.
.lg_server_dir <- function() {
  # After install, system.file() finds inst/server inside the package.
  path <- system.file("server", package = "langgraphr")
  # During development (not installed) fall back to the source layout.
  if (!nzchar(path)) {
    path <- file.path(getwd(), "langgraphr", "inst", "server")
  }
  # Return the resolved server directory.
  path
}

# ---- Health check ------------------------------------------------------------
# .lg_healthy returns TRUE when the server answers /health with status ok.
.lg_healthy <- function(port, timeout_ms = 1500) {
  # Any failure (connection refused, timeout, wrong body) means not healthy.
  tryCatch({
    # Ask the server for its health JSON.
    out <- .lg_get(port, "/health")
    # Healthy only when the server explicitly says status == "ok".
    isTRUE(out$status == "ok")
  }, error = function(e) FALSE)   # any error quietly means "not healthy yet"
}

# ---- Start -------------------------------------------------------------------
# lg_start_server spawns the hidden server and waits until it is ready.
lg_start_server <- function(port = getOption("langgraphr.port", 8123L),
                            wait = TRUE,
                            timeout = getOption("langgraphr.timeout", 60L),
                            logfile = NULL) {
  # If a healthy server is already running on this port, do nothing.
  if (.lg_healthy(port)) {
    # Inform the user that the server is already up.
    cli::cli_alert_success("langgraphr server already running on :{port}")
    # Return the port invisibly so the call can be piped.
    return(invisible(port))
  }

  # Resolve where the bundled Python server files live.
  server_dir <- .lg_server_dir()
  # If the bundle is missing, abort with the resolved path in the message.
  if (!dir.exists(server_dir)) {
    cli::cli_abort("Server bundle not found at {server_dir}")
  }

  # Pick which python/uv to launch the server with.
  python <- .lg_resolve_python(server_dir)
  # Server logs go to a temp file by default (never spam the console).
  logfile <- logfile %||% file.path(tempdir(), "langgraphr-server.log")
  # Remove a trailing .exe so we can detect "uv" regardless of platform.
  stem <- sub("[.]exe$", "", basename(python), ignore.case = TRUE)
  # is_uv is TRUE when the chosen runner is the uv command.
  is_uv <- identical(tolower(stem), "uv")

  # Build the command-line arguments for launching uvicorn.
  args <- if (is_uv) {
    # With uv we run inside the project venv (created by setup script).
    c("run", "--project", server_dir, "python", "-m", "uvicorn",
      "app:app", "--host", "127.0.0.1",
      "--port", as.character(port), "--log-level", "warning")
  } else {
    # With a plain python we call uvicorn as a module directly.
    c("-m", "uvicorn", "app:app", "--host", "127.0.0.1",
      "--port", as.character(port), "--log-level", "warning")
  }

  # The child process inherits the current R session environment so model
  # settings (LANGGRAPHR_MODEL etc.) set by the user flow through.
  env <- Sys.getenv()

  # Spawn the hidden server as a supervised background process.
  proc <- processx::process$new(
    command = python,     # the python/uv executable to run
    args = args,          # uvicorn arguments built above
    wd = server_dir,      # working directory = folder with app.py
    env = env,            # environment variables to pass through
    stdout = logfile,     # capture normal output into the log file
    stderr = logfile,     # capture errors into the same log file
    supervise = TRUE      # auto-kill the process when R exits
  )
  # Remember the process handle so we can stop it later.
  .lg_env$proc <- proc

  # If the caller asked us to wait for readiness, poll /health.
  if (wait) {
    # deadline = the wall-clock time when we give up waiting.
    deadline <- Sys.time() + timeout
    # ok starts FALSE and becomes TRUE once the server responds.
    ok <- FALSE
    # Poll until the deadline passes.
    while (Sys.time() < deadline) {
      # If the process died, waiting further is pointless.
      if (!proc$is_alive()) break
      # If the server answers /health we are ready.
      if (.lg_healthy(port)) { ok <- TRUE; break }
      # Pause briefly between polls to avoid hammering the port.
      Sys.sleep(0.3)
    }
    # If we never became healthy, read the log tail and abort.
    if (!ok) {
      # Read every line currently in the server log file.
      tail <- paste(readLines(logfile, warn = FALSE), collapse = "\n")
      # Abort with the log tail so the user can diagnose the problem.
      cli::cli_abort(c(
        "langgraphr server failed to start within {timeout}s.",
        "x" = substr(tail, 1, 1500)
      ))
    }
    # Tell the user the server is ready.
    cli::cli_alert_success("langgraphr server ready on :{port}")
  }

  # Return the port invisibly for piping.
  invisible(port)
}

# ---- Stop ---------------------------------------------------------------------
# lg_stop_server kills the hidden server process we spawned, if any.
lg_stop_server <- function() {
  # Read the stored process handle (NULL when nothing was started).
  proc <- .lg_env$proc
  # Only act when there is a handle and the process is still alive.
  if (!is.null(proc) && proc$is_alive()) {
    # Kill the process; wrapped in try so a race cannot break unloading.
    try(proc$kill(), silent = TRUE)
  }
  # Clear the stored handle so we do not try to kill it twice.
  .lg_env$proc <- NULL
  # Return nothing useful.
  invisible(NULL)
}
```
