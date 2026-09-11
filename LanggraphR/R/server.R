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

# ---- System proxy detection --------------------------------------------------
# .lg_detect_system_proxy finds the machine's outbound proxy without any
# user configuration: first the standard environment variables, then (on
# Windows) the system proxy in the registry. This matters because some
# VPN clients reset Python's TLS connections while R's curl still works;
# routing the sidecar through the same proxy as R fixes that.
.lg_detect_system_proxy <- function() {
  # Standard env vars win (they are cross-platform by definition).
  p <- Sys.getenv("HTTPS_PROXY", Sys.getenv("https_proxy",
         Sys.getenv("HTTP_PROXY", Sys.getenv("http_proxy", ""))))
  # Also honour an explicit langgraphr override.
  p <- Sys.getenv("LANGGRAPHR_PROXY", unset = p)
  if (nzchar(p)) return(p)
  # Windows only: read the system proxy from the user registry.
  if (.Platform$OS.type == "windows") {
    tryCatch({
      en <- utils::readRegistry(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
        "HKCU", maxlevel = 1)
      if (identical(en$ProxyEnable, 1L) && !is.null(en$ProxyServer) &&
          nzchar(en$ProxyServer)) {
        .lg_normalize_proxy(en$ProxyServer)
      } else ""
    }, error = function(e) "")
  } else ""
}

# .lg_normalize_proxy turns a registry ProxyServer value into a URL.
# It may be "host:port" or per-scheme "http=host:port;https=host:port".
.lg_normalize_proxy <- function(srv) {
  # Per-scheme form (contains '='), with or without the semicolons.
  if (grepl("=", srv)) {
    m <- regmatches(srv, regexec("https=([^;]+)", srv))[[1]]
    srv <- if (length(m) > 1) m[2] else {
      m2 <- regmatches(srv, regexec("http=([^;]+)", srv))[[1]]
      if (length(m2) > 1) m2[2] else return("")
    }
  }
  # Add the scheme when it is missing.
  if (!grepl("://", srv)) srv <- paste0("http://", srv)
  srv
}

#' Start the hidden LangGraph server
#'
#' Spawns the bundled Python/FastAPI sidecar as a supervised background
#' process and waits until it answers `/health`. Called automatically by
#' [lg_connect()] and [lg_compile()]; only call it directly to pre-warm the
#' server or to control the network route.
#'
#' @param port Port for the server (default from the `langgraphr.port`
#'   option, otherwise 8123).
#' @param wait Wait for the server to become healthy before returning?
#' @param timeout Seconds to wait for the server to become healthy.
#' @param logfile Where to write server logs. Defaults to a temp file;
#'   pass a path to keep the log.
#' @param proxy Network route for the sidecar's model traffic: `"auto"`
#'   (detect the system proxy), `"system"` (force the detected proxy) or
#'   `"direct"` (bypass every proxy).
#' @param extra_env Named character vector of extra environment variables
#'   for the sidecar process.
#' @return The port, invisibly.
#' @export
lg_start_server <- function(port = getOption("langgraphr.port", 8123L),
                            wait = TRUE,
                            timeout = getOption("langgraphr.timeout", 60L),
                            logfile = NULL,
                            proxy = c("auto", "system", "direct"),
                            extra_env = NULL) {
  # Validate the requested network route.
  mode <- match.arg(proxy)
  # If a healthy server is already running on this port, only restart it
  # when the caller explicitly asked for a DIFFERENT route than the one
  # it is currently using.
  if (.lg_healthy(port)) {
    want <- if (mode == "auto") NULL else mode
    if (is.null(want) || identical(.lg_env$proxy_mode, want)) {
      # Inform the user that the server is already up.
      cli::cli_alert_success("langgraphr server already running on :{port}")
      # Return the port invisibly so the call can be piped.
      return(invisible(port))
    }
    # Route change requested: replace the running server.
    lg_stop_server()
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

  # Set the network route for the sidecar. With "auto" we detect the
  # system proxy (env vars, then the Windows registry); with "direct" we
  # clear every proxy variable and bypass any VPN-level HTTP proxy; with
  # "system" we force the detected proxy even if env vars are unset.
  if (identical(mode, "direct")) {
    env[c("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy")] <- ""
    env["NO_PROXY"] <- "*"
    env["no_proxy"] <- "*"
    .lg_env$proxy_mode <- "direct"
  } else {
    sys_proxy <- .lg_detect_system_proxy()
    if (nzchar(sys_proxy)) {
      env["HTTP_PROXY"] <- env["HTTPS_PROXY"] <- sys_proxy
      env["http_proxy"] <- env["https_proxy"] <- sys_proxy
      # Loopback traffic (the local relay) must always bypass the proxy.
      env["NO_PROXY"] <- "127.0.0.1,localhost"
      env["no_proxy"] <- "127.0.0.1,localhost"
      .lg_env$proxy_mode <- "system"
    } else {
      .lg_env$proxy_mode <- "direct"
    }
  }

  # Apply caller-supplied environment overrides (used by the automatic
  # relay fallback to point the sidecar at the local relay).
  if (!is.null(extra_env)) {
    env[names(extra_env)] <- extra_env
  }

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

#' Stop the hidden LangGraph server
#'
#' Kills the sidecar process tree at the OS level and clears the stored
#' handle. Called automatically when the package is unloaded or R exits.
#'
#' @return `NULL`, invisibly.
#' @export
lg_stop_server <- function() {
  # Read the stored process handle (NULL when nothing was started).
  proc <- .lg_env$proc
  # Only act when there is a handle.
  if (!is.null(proc)) {
    # Remember the OS pid before touching the handle.
    pid <- tryCatch(as.character(proc$get_pid()), error = function(e) NULL)
    # Kill the process tree (uvicorn children too); wrapped so a race
    # cannot break unloading.
    if (proc$is_alive()) try(proc$kill_tree(), silent = TRUE)
    # Belt and braces: kill at the OS level as well, so the server can
    # never survive as an orphan holding port 8123 and a stale registry
    # (which previously happened when only the handle was killed).
    if (!is.null(pid) && nzchar(pid)) {
      if (.Platform$OS.type == "windows") {
        system2("taskkill", c("/PID", pid, "/T", "/F"),
                stdout = FALSE, stderr = FALSE)
      } else {
        system2("kill", c("-9", pid), stdout = FALSE, stderr = FALSE)
      }
    }
  }
  # Fallback for servers started by ANOTHER R process (the handle is
  # per-process: a callr worker running the route-switch rescue sees
  # NULL here). Kill whatever is listening on the port at the OS level,
  # so replacing the sidecar actually works from any process.
  pids <- .lg_pids_listening_on(getOption("langgraphr.port", 8123L))
  for (pid in pids) {
    if (.Platform$OS.type == "windows") {
      system2("taskkill", c("/PID", pid, "/T", "/F"),
              stdout = FALSE, stderr = FALSE)
    } else {
      system2("kill", c("-9", pid), stdout = FALSE, stderr = FALSE)
    }
  }
  # Clear the stored handle so we do not try to kill it twice.
  .lg_env$proc <- NULL
  # Return nothing useful.
  invisible(NULL)
}

# .lg_pids_listening_on(port) - PIDs of processes listening on a TCP
# port, discovered at the OS level (locale-independent).
.lg_pids_listening_on <- function(port) {
  # Windows: PowerShell's Get-NetTCPConnection is structured and immune
  # to localized netstat output.
  if (.Platform$OS.type == "windows") {
    out <- tryCatch(
      system2("powershell", c("-NoProfile", "-Command",
              paste0("Get-NetTCPConnection -LocalPort ", port,
                     " -State Listen -ErrorAction SilentlyContinue | ",
                     "Select-Object -ExpandProperty OwningProcess")),
              stdout = TRUE, stderr = FALSE),
      error = function(e) character(0))
  } else {
    out <- tryCatch(
      system2("lsof", c("-t", paste0("-i:", port), "-sTCP:LISTEN"),
              stdout = TRUE, stderr = FALSE),
      error = function(e) character(0))
  }
  # Keep only well-formed numeric pids (drops headers and blank lines).
  pids <- trimws(out)
  unique(pids[grepl("^\\d+$", pids)])
}
