# app.R - Shiny chat UI for the r_chatbot bot.
#
# Run:  shiny::runApp("projects/r_chatbot/app.R")
# (or open this file in Positron and use its Run button)
#
# The UI reuses the chatbot's brain (R/graph.R, R/tools.R) unchanged.
# Every agent call runs in a BACKGROUND R process (callr + promises), so
# the app stays fully responsive - no freezing, no "connection lost"
# overlay - while Ada is thinking.

# --- Locate project files no matter how the app is launched -------------
# 1) source() knows the file's folder; 2) Rscript exposes --file=;
# 3) fall back to the working directory.
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
       file.path(script_dir, ".env"),
       ").\nCreate it from .Renviron.example and add your API key.")
}
dotenv::load_dot_env(env_path)

# TRUE = conversations survive between R sessions (SQLite checkpointing).
USE_PERSISTENT_MEMORY <- TRUE

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(shinychat)
  library(promises)
  library(callr)
  library(later)
  # The chatbot engine: lg_thread_id(), lg_connect(), lg_use_sqlite().
  library(langgraphr)
})

source(file.path(script_dir, "R", "utils.R"))
source(file.path(script_dir, "R", "tools.R"))
source(file.path(script_dir, "R", "graph.R"))

# bg_promise() - run fun(args) in a background R process and get a promise
# for its result. The Shiny session polls the job on its event loop, so it
# never blocks.
bg_promise <- function(fun, args) {
  promises::promise(function(resolve, reject) {
    job <- callr::r_bg(fun, args)
    poll <- NULL
    poll <- function() {
      if (job$is_alive()) {
        later::later(poll, 0.25)
      } else {
        # get_result() throws if the worker failed; route that to reject().
        tryCatch(resolve(job$get_result()), error = function(e) reject(e))
      }
    }
    later::later(poll, 0.25)
  })
}

# Values the background worker needs (serialized once per call).
worker_tools <- tool_registry()

ui <- page_fillable(
  title = "Ada - r_chatbot",
  theme = bs_theme(preset = "shiny"),
  layout_sidebar(
    sidebar = sidebar(
      p("Chat with Ada - pure R, powered by langgraphr."),
      actionButton("clear", "New conversation",
                   class = "btn-outline-primary"),
      br(),
      textOutput("status"),
      width = 260
    ),
    chat_ui(
      "chat",
      placeholder = "Type a message...",
      height = "100%",
      fill = TRUE
    )
  )
)

server <- function(input, output, session) {
  # thread_id keys the conversation memory on the server. With persistent
  # memory on, the last-used thread id is saved next to the app, so
  # restarting the app continues the SAME conversation instead of
  # starting a blank one every launch.
  thread_file <- file.path(script_dir, "chatbot_thread_id.txt")
  saved_tid <- NULL
  if (file.exists(thread_file)) {
    tid <- trimws(readLines(thread_file, warn = FALSE)[1])
    if (nzchar(tid)) saved_tid <- tid
  }
  if (is.null(saved_tid)) {
    # Nothing saved: brand-new conversation, needs the personality seed.
    thread_id <- reactiveVal(lg_thread_id())
    needs_seed <- reactiveVal(TRUE)
  } else {
    # Saved thread found: its full history (including the personality
    # seed) already lives on the server, so no re-seeding is needed.
    thread_id <- reactiveVal(saved_tid)
    needs_seed <- reactiveVal(FALSE)
  }
  # turns: user messages so far in the current conversation.
  turns <- reactiveVal(0L)
  # busy: TRUE while a background worker is generating a reply.
  busy <- reactiveVal(FALSE)

  output$status <- renderText({
    if (busy()) "Ada is thinking..." else "Ready."
  })

  # The chat input fires when the user submits a message; the user's own
  # message is shown in the transcript automatically by shinychat.
  observeEvent(input$chat_user_input, {
    msg <- trimws(input$chat_user_input)
    req(nzchar(msg))
    # Ignore submits while a reply is already being generated.
    if (busy()) {
      chat_append("chat", "_Still thinking - one moment..._")
      return()
    }
    # Seed the personality when this thread is fresh (once per thread).
    seed <- if (needs_seed()) {
      paste0("System note: ", PERSONALITY,
             " Acknowledge by replying with exactly: Ready.")
    } else NULL

    busy(TRUE)
    # One full turn in a background process: reconnect by thread_id,
    # register tools, invoke, apply the summarize step when due.
    bg_promise(chat_turn, list(
      msg = msg,
      thread_id = thread_id(),
      turn_count = turns() + 1L,
      personality = PERSONALITY,
      seed = seed,
      tools = worker_tools,
      summary_every = SUMMARY_EVERY,
      env_path = env_path,
      durable = USE_PERSISTENT_MEMORY,
      db_path = file.path(script_dir, "chatbot_memory.sqlite")
    ))$
      then(function(res) {
        chat_append("chat", res$content)
        if (!is.null(res$note)) {
          chat_append("chat", paste0("_", res$note, "_"))
        }
        # Track thread id (a compression may have moved the conversation),
        # turn count, and the seeded flag. The thread id is also saved to
        # disk so the next app launch resumes this same conversation.
        thread_id(res$thread_id)
        writeLines(res$thread_id, thread_file)
        turns(turns() + 1L)
        needs_seed(FALSE)
        busy(FALSE)
      })$
      catch(function(err) {
        chat_append("chat", paste0("**Error:** ", conditionMessage(err)))
        busy(FALSE)
      })
  })

  # "New conversation": fresh thread id, cleared transcript, re-seeded
  # personality on the next message.
  observeEvent(input$clear, {
    if (busy()) {
      chat_append("chat", "_Wait for the current reply, then clear._")
      return()
    }
    new_tid <- lg_thread_id()
    thread_id(new_tid)
    # Save the fresh thread id too, so the next launch starts from the
    # cleared state rather than resuming the old conversation.
    writeLines(new_tid, thread_file)
    turns(0L)
    needs_seed(TRUE)
    chat_clear("chat")
    chat_append("chat", "_New conversation started - memory cleared._")
  })
}

shinyApp(ui, server)
