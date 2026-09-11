# app.R - ReAct agent: a GLM (Z.ai)-style Shiny chat UI for langgraphr.
#
# Run:  shiny::runApp("projects/react_agent/app.R")
#
# The agent turn runs in a BACKGROUND R process (callr + promises) so the
# UI never freezes. The worker streams every REASON / ACT / OBSERVE step
# of the ReAct loop to a JSON-lines event file, which this app polls every
# 600 ms to render the tool activity card in real time.
#
# Latency notes:
# - Tools are NOT all sent to the model. relevant_tool_defs() in agent.R
#   registers only the tools plausibly needed for the user's question, so
#   a plain chat question pays for zero tool schemas and gets a faster
#   first token.
# - Tools live in the background; there is no tool sidebar in the UI.

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

# Credentials.
env_candidates <- c(file.path(script_dir, ".env"), ".env")
env_path <- env_candidates[file.exists(env_candidates)][1]
if (is.na(env_path)) {
  stop("No .env file found next to app.R (expected at: ",
       file.path(script_dir, ".env"),
       ").\nCreate it with your LANGGRAPHR_* settings.")
}
dotenv::load_dot_env(env_path)

# Model name shown in the top-bar chip (GLM-style model picker).
model_label <- Sys.getenv("LANGGRAPHR_MODEL", unset = "GLM")

# Shiny rejects uploads over 5 MB by default - raise it so real CSVs
# and PDFs go through.
options(shiny.maxRequestSize = 100 * 1024^2)

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(shinyjs)
  library(jsonlite)
  library(promises)
  library(callr)
  library(later)
  library(langgraphr)
})

source(file.path(script_dir, "R", "utils.R"))
source(file.path(script_dir, "R", "tools.R"))
source(file.path(script_dir, "R", "agent.R"))

# bg_promise() - run fun(args) in a background R process and get a promise
# for its result; the Shiny session polls the job without blocking. A
# watchdog kills jobs that run past timeout_s so a hung model call can
# never leave the app stuck in "Thinking..." forever.
bg_promise <- function(fun, args, timeout_s = 300) {
  promises::promise(function(resolve, reject) {
    job <- callr::r_bg(fun, args)
    started <- Sys.time()
    poll <- NULL
    poll <- function() {
      if (job$is_alive()) {
        if (difftime(Sys.time(), started, units = "secs") > timeout_s) {
          try(job$kill_tree(), silent = TRUE)
          try(job$kill(), silent = TRUE)
          reject(simpleError(paste0(
            "Agent turn timed out after ", timeout_s,
            "s and was stopped. Check your network/VPN route, ",
            "then send the message again.")))
          return()
        }
        later::later(poll, 0.25)
      } else {
        tryCatch(resolve(job$get_result()), error = function(e) reject(e))
      }
    }
    later::later(poll, 0.25)
  })
}

# Theme foundation: GLM (Z.ai)-style light theme; styles.css does the rest.
theme <- bs_theme(
  bg = "#f4f6f9", fg = "#1f2329", primary = "#3859ff",
  preset = "shiny")

ui <- bslib::page(
  theme = theme,
  shinyjs::useShinyjs(),
  tags$head(
    tags$link(rel = "stylesheet",
              href = paste0("https://fonts.googleapis.com/css2?",
                            "family=Inter:wght@400;500;600&",
                            "family=JetBrains+Mono:wght@400;600&",
                            "display=swap")),
    tags$link(rel = "stylesheet", href = "styles.css")
  ),
  tags$script(HTML("
    // Enter sends, Shift+Enter makes a new line. The value is pushed
    // with priority 'event' so it is never stale.
    $(document).on('keydown', '#msg', function(e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        var v = $('#msg').val();
        if (v && v.trim()) {
          Shiny.setInputValue('submit_msg', v, {priority: 'event'});
          $('#msg').val('');
          $('#msg').css('height', 'auto');
        }
      }
    });
    // The textarea grows up to ~5 lines, then scrolls.
    $(document).on('input', '#msg', function() {
      this.style.height = 'auto';
      this.style.height = Math.min(this.scrollHeight, 130) + 'px';
    });
  ")),
  div(class = "shell",
    tags$header(class = "topbar",
      div(class = "brand",
          span(class = "logo-mark"), "Ada",
          span(class = "brand-sub", "ReAct agent")),
      div(class = "model-chip", model_label,
          span(class = "caret", "\u25BE")),
      div(class = "spacer"),
      uiOutput("status_ui"),
      actionButton("new_thread", label = "New chat", icon = icon("plus"),
                   class = "btn-newchat")
    ),
    tags$main(class = "main",
      div(id = "feed-scroll", class = "feed",
        div(class = "feed-inner", uiOutput("feed"))),
      div(class = "composer",
        div(class = "composer-inner",
          div(class = "composer-box",
            # Native label-for activation: clicking the paperclip opens
            # the file picker with no JS involved (robust in every
            # browser and embedded viewer).
            tags$label(class = "icon-btn", `for` = "upload",
                       title = "Attach a CSV, Excel, PDF or text file",
                       icon("paperclip")),
            div(class = "file-hidden",
              fileInput("upload", NULL,
                        accept = c(".csv", ".xlsx", ".xls", ".pdf", ".txt"))),
            textAreaInput("msg", NULL, rows = 1, resize = "none",
                          placeholder = "Message Ada..."),
            actionButton("send", icon("arrow-up"), class = "btn-send",
                         title = "Send")
          ),
          div(class = "disclaimer",
              paste0("Ada fetches live data and reads your files when ",
                     "needed - tool calls run locally."))
        )
      )
    )
  )
)

server <- function(input, output, session) {
  # ---- per-session upload folder -----------------------------------------
  # Uploaded files are copied here; the file tools resolve bare names
  # against this folder, and list_uploaded_files reads its manifest.
  updir <- file.path(tempdir(),
                     paste0("react-uploads-", session$token))
  dir.create(updir, recursive = TRUE, showWarnings = FALSE)
  manifest <- file.path(updir, "upload_manifest.json")
  # Names in this session's upload manifest (empty if nothing uploaded).
  uploaded_files <- function() {
    if (file.exists(manifest)) {
      as.character(jsonlite::fromJSON(manifest, simplifyVector = TRUE))
    } else character(0)
  }

  # ---- shared state --------------------------------------------------------
  vals <- reactiveValues(
    thread_id = lg_thread_id(),  # memory key for this conversation
    status = "ready",            # ready | thinking | error
    feed = character(0),         # finished feed items (HTML)
    events = list(),             # ReAct events of the in-flight turn
    lines_done = 0L,             # event lines already consumed
    events_file = NULL           # this turn's JSONL stream
  )

  output$thread_id <- renderText(vals$thread_id)

  output$status_ui <- renderUI({
    cls <- switch(vals$status,
                  ready = "dot-ready", thinking = "dot-thinking",
                  error = "dot-error")
    txt <- switch(vals$status,
                  ready = "Ready", thinking = "Thinking...",
                  error = "Error")
    span(class = "status",
         span(class = paste0("dot ", cls)),
         span(class = "status-text", txt))
  })

  # push_feed() - append one finished HTML item to the feed.
  push_feed <- function(html) vals$feed <- c(vals$feed, html)

  # ---- file uploads ---------------------------------------------------------
  observeEvent(input$upload, {
    f <- input$upload
    req(f)
    ok <- file.copy(f$datapath, file.path(updir, f$name), overwrite = TRUE)
    if (!ok) {
      push_feed(note_html("Upload failed - could not copy the file."))
      return()
    }
    # Update the manifest the tools read.
    jsonlite::write_json(unique(c(uploaded_files(), f$name)), manifest,
                         auto_unbox = TRUE)
    push_feed(note_html(paste0(
      "Uploaded: ", f$name,
      " - ask me about it in your next message.")))
  })

  # ---- sending a message ----------------------------------------------------
  send_message <- function(msg) {
    msg <- trimws(msg)
    req(nzchar(msg))
    if (identical(vals$status, "thinking")) return()
    push_feed(user_bubble_html(msg))
    vals$status <- "thinking"
    shinyjs::disable("send")
    # Fresh event stream for this turn.
    vals$events_file <- tempfile(fileext = ".jsonl")
    file.create(vals$events_file)
    vals$events <- list()
    vals$lines_done <- 0L
    # Make uploaded files usable: name them for the model and always
    # register the file tools for this turn (react_worker -> add_tool).
    files <- uploaded_files()
    worker_msg <- if (length(files)) paste0(
      msg, "\n\n[Files uploaded this session: ",
      paste(files, collapse = ", "), "]") else msg
    bg_promise(react_worker, list(
      msg = worker_msg,
      thread_id = vals$thread_id,
      upload_dir = updir,
      events_file = vals$events_file,
      env_path = env_path,
      source_dir = script_dir,
      upload_files = files
    ))$
      then(function(res) {
        # The finished tool card replaces the live one (now collapsed).
        push_feed(tool_card_html(vals$events, open = FALSE))
        push_feed(agent_bubble_html(
          parse_agent_response(first_or(res$content, "(no reply)"))))
        vals$status <- "ready"
        shinyjs::enable("send")
      })$
      catch(function(err) {
        vals$status <- "error"
        push_feed(agent_bubble_html(
          parse_agent_response(paste0("**Error:** ",
                                      conditionMessage(err)))),
          error = TRUE)
        shinyjs::enable("send")
      })
  }
  observeEvent(input$submit_msg, send_message(input$submit_msg))
  observeEvent(input$send, send_message(input$msg))

  # ---- new thread ------------------------------------------------------------
  observeEvent(input$new_thread, {
    if (identical(vals$status, "thinking")) return()
    vals$thread_id <- lg_thread_id()
    push_feed(note_html("New chat started - memory cleared."))
  })

  # ---- live ReAct event polling ---------------------------------------------
  # While a turn is running, read any new JSONL lines and append them to
  # vals$events; the feed re-renders with the updated tool card.
  observe({
    invalidateLater(600, session)
    if (!identical(vals$status, "thinking")) return()
    ef <- vals$events_file
    if (is.null(ef) || !file.exists(ef)) return()
    lines <- readLines(ef, warn = FALSE)
    if (length(lines) <= vals$lines_done) return()
    new <- lines[(vals$lines_done + 1L):length(lines)]
    parsed <- Filter(Negate(is.null), lapply(new, function(l) {
      tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE),
               error = function(e) NULL)
    }))
    vals$events <- c(vals$events, parsed)
    vals$lines_done <- length(lines)
  })

  # ---- feed rendering ---------------------------------------------------------
  # Finished items plus the in-flight tool card (kept expanded while live).
  # With nothing to show yet, render the DeepSeek-style greeting + chips.
  output$feed <- renderUI({
    items <- vals$feed
    if (identical(vals$status, "thinking")) {
      live <- tool_card_html(vals$events, open = TRUE)
      if (!nzchar(live)) live <- note_html("Ada is thinking...")
      items <- c(items, live)
    }
    if (length(items) == 0L) return(HTML(greeting_html()))
    HTML(paste(items, collapse = "\n"))
  })

  # Keep the feed scrolled to the newest message.
  observe({
    invalidateLater(800, session)
    shinyjs::runjs(paste0(
      "var f = document.getElementById('feed-scroll');",
      "if (f) f.scrollTop = f.scrollHeight;"))
  })
}

shinyApp(ui, server)
