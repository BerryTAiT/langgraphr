# app.R - AutoPatch chat UI, stock shinychat look.
#
# Run:  shiny::runApp("projects/autopatch/app.R")
#
# The brain is R/chat.R (persona + 7 tools), unchanged. Every agent turn
# runs in a BACKGROUND R process (callr + promises) so the app stays fully
# responsive while the model works. Conversation memory survives app
# restarts: the thread id is saved to chat_thread_id.txt and the server
# checkpoints threads into autopatch.db (SQLite).
#
# No custom theme, no sidebar, no extra chrome - just the default shinychat
# feed + input box, with a single "New conversation" button.

# --- Locate project files no matter how the app is launched -------------
script_dir <- getSrcDirectory(function() {})
if (length(script_dir) == 0L || !nzchar(script_dir)) {
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE),
                   value = TRUE)
  if (length(file_arg) >= 1L) {
    script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg[1]),
                                        winslash = "/"))
  }
}
if (length(script_dir) == 0L || !nzchar(script_dir)) script_dir <- getwd()
script_dir <- normalizePath(script_dir, winslash = "/")

# Credentials: prefer the .env next to this file, then the working dir.
env_candidates <- c(file.path(script_dir, ".env"), ".env")
env_path <- env_candidates[file.exists(env_candidates)][1]
if (is.na(env_path)) {
  stop("No .env file found next to app.R (expected at: ",
       file.path(script_dir, ".env"), ")")
}
dotenv::load_dot_env(env_path)

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(shinychat)
  library(promises)
  library(callr)
  library(later)
  library(langgraphr)
})

source(file.path(script_dir, "R", "chat.R"))

# Fixed targets this app chats about.
AP_REPO <- file.path(script_dir, "sample_repo")
AP_PATCHES <- file.path(script_dir, "patches")
AP_DB <- file.path(script_dir, "autopatch.db")
AP_THREAD_FILE <- file.path(script_dir, "chat_thread_id.txt")

# Durable memory: takes effect when this process (or the first background
# worker) boots the hidden server; harmless if it already runs.
lg_use_sqlite(AP_DB)

# bg_promise() - run fun(args) in a background R process and get a promise
# for its result. The Shiny session polls the job on its event loop, so it
# never blocks. (Same pattern as projects/r_chatbot and react_agent.)
bg_promise <- function(fun, args) {
  promises::promise(function(resolve, reject) {
    job <- callr::r_bg(fun, args)
    poll <- NULL
    poll <- function() {
      if (job$is_alive()) {
        later::later(poll, 0.25)
      } else {
        tryCatch(resolve(job$get_result()), error = function(e) reject(e))
      }
    }
    later::later(poll, 0.25)
  })
}

ui <- page_fillable(
  title = "AutoPatch",
  tags$div(
    class = "d-flex justify-content-between align-items-center",
    tags$h5("AutoPatch", class = "mb-0 text-secondary"),
    actionButton("clear", "New conversation",
                 class = "btn-outline-secondary btn-sm")
  ),
  chat_ui(
    "chat",
    placeholder = "Type a message...",
    height = "100%",
    fill = TRUE
  )
)

server <- function(input, output, session) {
  # thread_id keys the conversation memory on the server. It is saved to
  # disk, so restarting the app continues the SAME conversation.
  saved_tid <- NULL
  if (file.exists(AP_THREAD_FILE)) {
    tid <- trimws(readLines(AP_THREAD_FILE, warn = FALSE)[1])
    if (nzchar(tid)) saved_tid <- tid
  }
  if (is.null(saved_tid)) {
    thread_id <- reactiveVal(lg_thread_id())
    needs_seed <- reactiveVal(TRUE)
  } else {
    thread_id <- reactiveVal(saved_tid)
    needs_seed <- reactiveVal(FALSE)
  }
  busy <- reactiveVal(FALSE)

  # The chat input fires when the user submits; shinychat shows the user's
  # message in the transcript by itself.
  observeEvent(input$chat_user_input, {
    msg <- trimws(input$chat_user_input)
    req(nzchar(msg))
    if (busy()) {
      chat_append("chat", "_Still thinking - one moment..._")
      return()
    }
    # ap_chat_turn wraps this in the "System note:" envelope itself.
    seed <- if (needs_seed()) AUTOPATCH_PERSONA else NULL

    busy(TRUE)
    # One full turn in a background process (self-contained worker).
    bg_promise(ap_chat_turn, list(
      msg = msg,
      thread_id = thread_id(),
      seed = seed,
      repo = AP_REPO,
      patches_root = AP_PATCHES,
      env_path = env_path,
      script_dir = script_dir,
      db_path = AP_DB
    ))$
      then(function(res) {
        chat_append("chat", res$content)
        thread_id(res$thread_id)
        writeLines(res$thread_id, AP_THREAD_FILE)
        needs_seed(FALSE)
        busy(FALSE)
      })$
      catch(function(err) {
        chat_append("chat", paste0("**Error:** ", conditionMessage(err)))
        busy(FALSE)
      })
  })

  # New conversation: fresh thread, cleared transcript, re-seed persona.
  observeEvent(input$clear, {
    if (busy()) {
      chat_append("chat", "_Wait for the current reply, then start a new conversation._")
      return()
    }
    new_tid <- lg_thread_id()
    thread_id(new_tid)
    writeLines(new_tid, AP_THREAD_FILE)
    needs_seed(TRUE)
    chat_clear("chat")
    chat_append("chat", "_New conversation started - memory cleared._")
  })
}

shinyApp(ui, server)
