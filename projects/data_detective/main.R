# main.R - Data Detective Agent console entry point
#
# A pure-R AI agent built with the langgraphr framework.
# No Python server, no external R packages beyond langgraphr.
#
# Run with: Rscript projects/data_detective/main.R
# Or: source("projects/data_detective/main.R")

# ---- setup ----------------------------------------------------------------

# Resolve this script's directory so paths work regardless of cwd
# Try multiple methods to find where main.R lives
script_dir <- NULL

# Method 1: sys.frames() search for ofile (works with source())
for (frame in rev(seq_len(sys.nframe()))) {
  ofile <- tryCatch(sys.frame(frame)$ofile, error = function(e) NULL)
  if (!is.null(ofile) && file.exists(ofile)) {
    candidate <- dirname(normalizePath(ofile, winslash = "/"))
    if (dir.exists(file.path(candidate, "R"))) {
      script_dir <- candidate
      break
    }
  }
}

# Method 2: check if R/ exists in cwd (run from project dir)
if (is.null(script_dir) && dir.exists("R")) {
  script_dir <- normalizePath(".", winslash = "/")
}

# Method 3: check sibling data_detective dir
if (is.null(script_dir)) {
  candidate <- file.path(dirname(getwd()), "data_detective")
  if (dir.exists(file.path(candidate, "R"))) {
    script_dir <- normalizePath(candidate, winslash = "/")
  }
}

# Method 4: check full path pattern in getwd()
if (is.null(script_dir)) {
  cwd <- getwd()
  if (grepl("data_detective", cwd)) {
    script_dir <- normalizePath(cwd, winslash = "/")
  }
}

# Fallback: assume current dir
if (is.null(script_dir)) {
  script_dir <- normalizePath(".", winslash = "/")
}

cat("Script directory:", script_dir, "\n")

# Load langgraphr (must be installed)
if (!requireNamespace("langgraphr", quietly = TRUE)) {
  stop("langgraphr must be installed. Run: devtools::install_local('LanggraphR')")
}

# Load project files
source(file.path(script_dir, "R", "modules_compat.R"), local = FALSE)
source(file.path(script_dir, "R", "tools.R"), local = TRUE)
source(file.path(script_dir, "R", "agent.R"), local = TRUE)

# Load .env if it exists
env_path <- NULL
candidates <- c(
  file.path(dirname(script_dir), "react_agent", ".env"),
  file.path(script_dir, ".env"),
  file.path(dirname(script_dir), ".env"),
  file.path(dirname(dirname(script_dir)), ".env")
)
for (p in candidates) {
  if (file.exists(p)) { env_path <- p; break }
}
if (!is.null(env_path)) {
  try(dotenv::load_dot_env(env_path), silent=TRUE)
}
# Use deepseek-chat (actual API model name)
Sys.setenv(LANGGRAPHR_MODEL = "deepseek-chat")

# ---- banner ---------------------------------------------------------------

banner <- function() {
  cat("\n")
  cat("========================================\n")
  cat("     Data Detective Agent v1.0\n")
  cat("     Powered by langgraphr + DeepSeek\n")
  cat("========================================\n")
  cat("\n")
  cat("Ask me to explore a dataset. I can:\n")
  cat("  - Load datasets (iris, mtcars, airquality)\n")
  cat("  - Compute summary statistics\n")
  cat("  - Detect outliers\n")
  cat("  - Find correlations\n")
  cat("  - Compare groups\n")
  cat("  - Show frequency tables\n")
  cat("\n")
  cat("Commands:\n")
  cat("  /status   - show agent state\n")
  cat("  /history  - show checkpoint history\n")
  cat("  /reset    - start fresh conversation\n")
  cat("  /rewind   - rewind to a checkpoint\n")
  cat("  /quit     - exit\n")
  cat("\n")
}

# ---- command handler ------------------------------------------------------

handle_command <- function(agent, input) {
  cmd <- tolower(trimws(input))

  if (cmd %in% c("/quit", "/exit", "/q")) {
    cat("Goodbye!\n")
    return(FALSE)
  }

  if (cmd == "/status") {
    agent$print()
    return(TRUE)
  }

  if (cmd == "/history") {
    checkpoints <- agent$get_history()
    if (length(checkpoints) == 0) {
      cat("No checkpoints yet.\n")
    } else {
      cat(sprintf("Checkpoints (%d):\n", length(checkpoints)))
      for (i in seq_along(checkpoints)) {
        cp <- checkpoints[[i]]
        cat(sprintf("  [%d] id=%s, step=%d, %s\n",
                    i,
                    substr(cp$checkpoint$id, 1, 12),
                    cp$checkpoint$channel_values$step %||% 0,
                    cp$metadata$run_id %||% ""))
      }
    }
    return(TRUE)
  }

  if (cmd == "/reset") {
    agent$reset()
    return(TRUE)
  }

  if (startsWith(cmd, "/rewind")) {
    parts <- strsplit(cmd, "\\s+")[[1]]
    if (length(parts) < 2) {
      cat("Usage: /rewind <checkpoint_number>\n")
      cat("Use /history to see available checkpoints.\n")
      return(TRUE)
    }
    idx <- as.integer(parts[2])
    checkpoints <- agent$get_history()
    if (idx < 1 || idx > length(checkpoints)) {
      cat("Invalid checkpoint number.\n")
      return(TRUE)
    }
    agent$rewind(checkpoints[[idx]]$checkpoint$id)
    return(TRUE)
  }

  # Not a command
  NULL
}

# ---- main loop ------------------------------------------------------------

run_detective <- function() {
  banner()

  agent <- detective_agent()

  while (TRUE) {
    cat("\n> ")
    input <- readline()

    # Skip empty input
    if (!nzchar(trimws(input))) next

    # Handle commands
    result <- handle_command(agent, input)
    if (isFALSE(result)) break
    if (!is.null(result)) next

    # Run the agent
    cat("Thinking...\n")
    response <- tryCatch({
      agent$invoke(input)
    }, error = function(e) {
      sprintf("Error: %s", conditionMessage(e))
    })

    cat("\n--- Data Detective ---\n")
    cat(response, "\n")
    cat("----------------------\n")
  }
}

# Run if called directly
if (interactive()) {
  run_detective()
} else {
  # Non-interactive: run a demo
  cat("\n=== Data Detective Demo (non-interactive) ===\n\n")

  agent <- detective_agent()

  cat("Step 1: Load iris dataset and analyze\n")
  response <- agent$invoke(
    "Load the iris dataset and tell me about its structure, then find any outliers in Sepal.Length."
  )
  cat("\n--- Response ---\n")
  cat(response, "\n")

  cat("\n\nStep 2: Check correlations\n")
  response <- agent$invoke(
    "Now check the correlations between all numeric columns."
  )
  cat("\n--- Response ---\n")
  cat(response, "\n")

  cat("\n\nStep 3: Compare groups\n")
  response <- agent$invoke(
    "Compare Petal.Length across the Species groups."
  )
  cat("\n--- Response ---\n")
  cat(response, "\n")

  cat("\n\n=== Agent Status ===\n")
  agent$print()

  cat("\n=== Checkpoint History ===\n")
  checkpoints <- agent$get_history()
  cat(sprintf("Total checkpoints: %d\n", length(checkpoints)))
  for (i in seq_along(checkpoints)) {
    cp <- checkpoints[[i]]
    cat(sprintf("  [%d] step=%d, %s\n",
                i,
                cp$checkpoint$channel_values$step %||% 0,
                cp$metadata$run_id %||% ""))
  }

  cat("\n=== Cross-thread Store ===\n")
  agent$remember("favorite_dataset", "iris")
  recalled <- agent$recall("favorite_dataset")
  cat("Recalled: favorite_dataset =", recalled$value, "\n")
}
