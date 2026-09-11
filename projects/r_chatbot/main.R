# main.R - entry point: a plain readline() chat loop.
#
# Run in the R console:
#   source("projects/r_chatbot/main.R")
#
# Commands while chatting:
#   clear       reset the conversation memory
#   quit/exit   leave the chat

# --- Locate the project files no matter how the app is launched ---------
# 1) source() in an R console: getSrcDirectory() knows this file's folder.
script_dir <- getSrcDirectory(function() {})
# 2) Rscript / "Run File": no source context, but the --file= argument
#    names this script - take its folder.
if (length(script_dir) == 0L || !nzchar(script_dir)) {
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE),
                   value = TRUE)
  if (length(file_arg) >= 1L) {
    script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg[1]),
                                        winslash = "/"))
  }
}
# 3) Last resort: the current working directory.
if (length(script_dir) == 0L || !nzchar(script_dir)) script_dir <- getwd()
script_dir <- normalizePath(script_dir, winslash = "/")

# USE_PERSISTENT_MEMORY - TRUE = conversations survive between R sessions
# (history is checkpointed to a SQLite file); FALSE = memory lives only
# while the server runs. Set also LANGGRAPHR_DB in .env if you want the
# server to pick the same file up on every boot.
USE_PERSISTENT_MEMORY <- FALSE

# --- Dependencies and project code ---------------------------------------
# langgraphr: lg_connect(), agent$add_tool(), agent$invoke(), thread_id,
# lg_use_sqlite(), agent$reset() - all explained inline in R/graph.R.
library(langgraphr)
# dotenv: loads LANGGRAPHR_MODEL / LANGGRAPHR_API_KEY / LANGGRAPHR_BASE_URL
# from the .env file sitting next to this script. A missing file gets a
# clear message instead of a cryptic one.
env_file <- file.path(script_dir, ".env")
if (!file.exists(env_file)) {
  stop("No .env file found next to main.R (expected at: ", env_file,
       ").\nCreate it from .Renviron.example and add your API key.")
}
dotenv::load_dot_env(env_file)

source(file.path(script_dir, "R", "utils.R"))
source(file.path(script_dir, "R", "tools.R"))
source(file.path(script_dir, "R", "graph.R"))

# --- Start the chatbot -----------------------------------------------------
# durable = USE_PERSISTENT_MEMORY hands lg_use_sqlite() the SQLite path
# inside this project folder, so history survives between R sessions.
agent <- new_chatbot(
  durable = USE_PERSISTENT_MEMORY,
  db_path = file.path(script_dir, "chatbot_memory.sqlite")
)

# turns counts user messages in the current conversation; it drives the
# summarize step and is reset by "clear".
turns <- 0L
print_banner()

# --- The conversation loop ---------------------------------------------------
repeat {
  # Read one line from the console.
  msg <- trimws(readline("You: "))

  # Empty input: just prompt again.
  if (!nzchar(msg)) next

  # Graceful exit on quit/exit (case-insensitive).
  if (tolower(msg) %in% c("quit", "exit")) {
    print_message("Ada", "Goodbye! Chat again any time.")
    break
  }

  # "clear" resets the conversation memory and re-seeds the personality.
  if (tolower(msg) == "clear") {
    agent <- clear_history(agent)
    turns <- 0L
    print_message("Ada", "(memory cleared - fresh conversation)")
    next
  }

  # Show a thinking note while the model (and possibly an R tool) works.
  print_message("Ada", "... thinking")

  # invoke() sends the message and drives the whole turn to completion:
  # the server runs the model, and whenever the model wants an R tool the
  # run pauses, your function executes locally, and the run resumes
  # automatically. Errors are shown in the chat instead of crashing.
  res <- tryCatch(agent$invoke(msg), error = function(e) e)

  if (inherits(res, "error")) {
    print_message("Ada", format_error(res))
    next
  }

  # Show the reply and count the completed turn.
  print_message("Ada", res$content)
  turns <- turns + 1L

  # After every SUMMARY_EVERY messages, compress the history (see graph.R).
  if (maybe_summarize(agent, turns)) {
    print_message("Ada", paste0(
      "(history compressed after ", SUMMARY_EVERY, " messages; ",
      "a summary was carried into the fresh conversation)"))
  }
}
