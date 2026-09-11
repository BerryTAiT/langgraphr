# app.R - RagChat: conversational RAG over your own documents, powered by
# langgraphr + ragnar + DuckDB.
#
# Run:  shiny::runApp("projects/rag_chat/app.R")
#
# Upload a document and it is indexed immediately in a background process
# (chunk + embed + vector store, streamed as JSONL progress events). Then
# ask as many questions as you like: every turn runs the langgraphr graph
# in R/graph.R (load memory -> rewrite query -> retrieve -> generate ->
# persist / summarize). Memory lives on disk per chat, so a page refresh
# or even an app restart picks the conversation back up.

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

env_path <- file.path(script_dir, ".env")
if (!file.exists(env_path)) {
  stop("No .env file found next to app.R (expected at: ", env_path,
       ").\nCopy .env and fill in your LANGGRAPHR_* / RAG_EMBED_* settings.")
}
dotenv::load_dot_env(env_path)

options(shiny.maxRequestSize = 200 * 1024^2)

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(shinyjs)
  library(jsonlite)
  library(promises)
  library(callr)
  library(later)
  library(duckdb)
})

source(file.path(script_dir, "R", "utils.R"))
source(file.path(script_dir, "R", "config.R"))
source(file.path(script_dir, "R", "store.R"))
source(file.path(script_dir, "R", "indexer.R"))
source(file.path(script_dir, "R", "graph.R"))

# bg_promise() - run fun(args) in a background R process and get a promise
# for its result; a watchdog kills jobs that run past timeout_s so a hung
# model call can never leave the app stuck. (Same pattern as the
# react_agent project.)
bg_promise <- function(fun, args, timeout_s = 600) {
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
            "The job timed out after ", timeout_s,
            "s and was stopped. Check your network route / embedding ",
            "backend, then try again.")))
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

cfg0 <- rag_config(script_dir)

theme <- bs_theme(
  bg = "#faf9f5", fg = "#1f1e1d", primary = "#d97757",
  preset = "shiny")

ui <- bslib::page(
  theme = theme,
  shinyjs::useShinyjs(),
  tags$head(
    tags$link(rel = "stylesheet",
              href = paste0("https://fonts.googleapis.com/css2?",
                            "family=Inter:wght@400;500;600&",
                            "family=JetBrains+Mono:wght@400;600&",
                            "family=Lora:wght@500;600&",
                            "display=swap")),
    tags$link(rel = "stylesheet", href = "styles.css")
  ),
  tags$script(HTML("
    // The chat identity lives in localStorage: refresh the page and the
    // same conversation (history + indexed files) reloads from disk.
    Shiny.addCustomMessageHandler('whoami', function(m) {
      var id = null;
      try { id = localStorage.getItem('sage_chat_id'); } catch (e) {}
      if (!id) {
        id = 'chat-' + Date.now().toString(36) +
             Math.random().toString(36).slice(2, 8);
        try { localStorage.setItem('sage_chat_id', id); } catch (e) {}
      }
      Shiny.setInputValue('chat_id', id, {priority: 'event'});
    });
    Shiny.addCustomMessageHandler('setChatId', function(id) {
      try { localStorage.setItem('sage_chat_id', id); } catch (e) {}
      Shiny.setInputValue('chat_id', id, {priority: 'event'});
    });
    // Enter sends, Shift+Enter makes a new line.
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
    $(document).on('input', '#msg', function() {
      this.style.height = 'auto';
      this.style.height = Math.min(this.scrollHeight, 130) + 'px';
    });
  ")),
  div(id = "shell", class = "shell",
    tags$aside(class = "sidebar",
      div(class = "side-head",
        div(class = "brand",
            span(class = "logo-mark", "\u2733"), "RagChat"),
        actionButton("collapse_side", icon("chevron-left"),
                     class = "btn-icon", title = "Collapse sidebar")),
      actionButton("new_thread", label = "New chat", icon = icon("plus"),
                   class = "btn-newchat side-new"),
      div(class = "side-label", "Recent"),
      div(class = "chat-list", uiOutput("chat_list"))
    ),
    div(class = "stage",
      tags$header(class = "topbar",
        actionButton("expand_side", icon("bars"),
                     class = "btn-icon side-expand", title = "Open sidebar"),
        div(class = "spacer"),
        uiOutput("status_ui")
      ),
      tags$main(class = "main",
      div(id = "feed-scroll", class = "feed",
        div(class = "feed-inner", uiOutput("feed"))),
      div(class = "composer",
        div(class = "composer-inner",
          div(class = "composer-box",
            textAreaInput("msg", NULL, rows = 1, resize = "none",
                          placeholder = "Ask about your documents"),
            div(class = "composer-row",
              tags$label(class = "icon-btn", `for` = "upload",
                         title = "Attach a PDF, Word, HTML, Markdown, text or table file",
                         icon("paperclip")),
              div(class = "file-hidden",
                fileInput("upload", NULL,
                          accept = c(".pdf", ".txt", ".md", ".markdown",
                                     ".csv", ".xlsx", ".xls",
                                     ".html", ".htm", ".docx", ".log"))),
              div(class = "composer-spacer"),
              actionButton("send", icon("arrow-up"), class = "btn-send",
                           title = "Send")
            )
          ),
          div(class = "disclaimer",
              paste0("Cites your indexed documents - chat memory survives ",
                     "refreshes and restarts."))
        )
      )
    )
    )
  )
)

server <- function(input, output, session) {
  vals <- reactiveValues(
    chat_id = NULL,
    status = "boot",        # boot | ready | indexing | thinking | error
    stage = "",             # current indexing stage for the status pill
    history_html = character(0),  # persisted bubbles (from the chat DB)
    transient = character(0),     # session-only notes (uploads, errors)
    files = list(),               # indexed files for the sources card
    stream = "",                  # answer tokens of the in-flight turn
    events_file = NULL,
    lines_done = 0L,
    side_tick = 0L
  )

  # ---- status pill ---------------------------------------------------------
  output$status_ui <- renderUI({
    cls <- switch(vals$status,
                  ready = "dot-ready", thinking = "dot-thinking",
                  indexing = "dot-thinking", error = "dot-error",
                  boot = "dot-thinking")
    txt <- switch(vals$status,
                  ready = "Ready",
                  boot = "Loading...",
                  indexing = if (nzchar(vals$stage)) vals$stage else "Indexing...",
                  thinking = "Thinking...",
                  error = "Error")
    span(class = "status",
         span(class = paste0("dot ", cls)),
         span(class = "status-text", txt))
  })

  push_transient <- function(html) {
    vals$transient <- c(vals$transient, html)
  }

  # ---- sidebar: recent conversations -----------------------------------------
  output$chat_list <- renderUI({
    # Re-renders on chat switch and whenever a turn or index completes.
    vals$chat_id
    vals$side_tick
    d <- chat_list_all(cfg0$data_dir)
    if (nrow(d) == 0L) {
      return(HTML('<div class="chat-empty">No conversations yet</div>'))
    }
    items <- vapply(seq_len(nrow(d)), function(i) {
      chat_item_html(d$chat_id[i], d$title[i], time_ago(d$updated[i]),
                     identical(d$chat_id[i], vals$chat_id))
    }, character(1))
    HTML(paste(items, collapse = "\n"))
  })

  observeEvent(input$open_chat, {
    if (!is.character(input$open_chat) || !nzchar(input$open_chat)) return()
    session$sendCustomMessage("setChatId", input$open_chat)
  })

  observeEvent(input$collapse_side, {
    shinyjs::addClass(class = "collapsed", selector = "#shell")
  })
  observeEvent(input$expand_side, {
    shinyjs::removeClass(class = "collapsed", selector = "#shell")
  })

  # ---- chat loading (fires on connect and on New chat) ----------------------
  reload_chat <- function() {
    id <- vals$chat_id
    p <- chat_paths(cfg0$data_dir, id)
    vals$history_html <- character(0)
    vals$transient <- character(0)
    vals$files <- list()
    vals$stream <- ""
    if (!file.exists(p$db)) {
      vals$status <- "ready"
      return()
    }
    d <- tryCatch(with_chat_db(p$db, function(con) list(
      msgs = chat_all_messages(con),
      files = chat_files(con),
      ready = chat_meta_get(con, "ready", "0")
    )), error = function(e) NULL)
    if (is.null(d)) {
      vals$status <- "error"
      push_transient(note_html("Could not open this chat's database."))
      return()
    }
    if (nrow(d$files) > 0L) {
      vals$files <- lapply(seq_len(nrow(d$files)), function(i) list(
        name = d$files$name[i], chunks = d$files$chunks[i]))
    }
    if (nrow(d$msgs) > 0L) {
      vals$history_html <- vapply(seq_len(nrow(d$msgs)), function(i) {
        if (identical(d$msgs$role[i], "user")) {
          user_bubble_html(d$msgs$content[i])
        } else {
          refs <- tryCatch(
            jsonlite::fromJSON(d$msgs$refs_json[i], simplifyVector = FALSE),
            error = function(e) list())
          agent_bubble_html(parse_agent_response(d$msgs$content[i]),
                            refs = first_or(refs, list()))
        }
      }, character(1))
    }
    vals$status <- "ready"
  }

  observeEvent(input$chat_id, {
    if (!is.character(input$chat_id) || !nzchar(input$chat_id)) return()
    vals$chat_id <- input$chat_id
    reload_chat()
  })
  session$sendCustomMessage("whoami", list())

  # ---- feed rendering ---------------------------------------------------------
  output$feed <- renderUI({
    items <- character(0)
    if (length(vals$files)) {
      items <- c(items, sources_card_html(vals$files))
    }
    items <- c(items, vals$history_html, vals$transient)
    if (identical(vals$status, "thinking")) {
      if (nzchar(vals$stream)) {
        items <- c(items, agent_bubble_html(paste0(
          parse_agent_response(vals$stream),
          '<span class="cursor"></span>')))
      } else {
        items <- c(items, note_html("RagChat is reading your documents..."))
      }
    }
    if (length(items) == 0L) return(NULL)
    HTML(paste(items, collapse = "\n"))
  })

  # ---- event polling (indexing progress + answer tokens) ----------------------
  observe({
    invalidateLater(400, session)
    if (!identical(vals$status, "thinking") &&
        !identical(vals$status, "indexing")) return()
    ef <- vals$events_file
    if (is.null(ef) || !file.exists(ef)) return()
    lines <- readLines(ef, warn = FALSE)
    if (length(lines) <= vals$lines_done) return()
    new <- lines[(vals$lines_done + 1L):length(lines)]
    vals$lines_done <- length(lines)
    parsed <- Filter(Negate(is.null), lapply(new, function(l) {
      tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE),
               error = function(e) NULL)
    }))
    for (e in parsed) handle_event(e)
  })

  handle_event <- function(e) {
    switch(e$type,
      token = {
        vals$stream <- paste0(vals$stream, first_or(e$text, ""))
      },
      stage = {
        if (identical(vals$status, "indexing")) {
          i <- first_or(e$i, ""); n <- first_or(e$n, "")
          where <- if (length(e$file)) paste0(": ", e$file) else ""
          vals$stage <- switch(first_or(e$stage, ""),
            "embed-check" = "Checking embedding backend...",
            "reading" = paste0("Reading ", i, "/", n, where),
            "chunking" = paste0("Chunking ", i, "/", n, where),
            "embedding" = paste0("Embedding ", i, "/", n,
                                 " (", first_or(e$chunks, "?"), " chunks)"),
            "building-index" = "Building search index...",
            "Indexing...")
        }
      },
      `file-done` = NULL,
      indexed = {
        p <- chat_paths(cfg0$data_dir, vals$chat_id)
        d <- tryCatch(with_chat_db(p$db, function(con) chat_files(con)),
                      error = function(e) NULL)
        if (!is.null(d) && nrow(d) > 0L) {
          vals$files <- lapply(seq_len(nrow(d)), function(i) list(
            name = d$name[i], chunks = d$chunks[i]))
        }
        push_transient(note_html(paste0(
          "Indexed ", first_or(e$n_files, "?"),
          " file(s) - ask away, I cite my sources.")))
        vals$status <- "ready"
        vals$side_tick <- vals$side_tick + 1L
        shinyjs::enable("upload")
        shinyjs::enable("send")
      },
      done = {
        refs <- first_or(e$refs, list())
        vals$history_html <- c(vals$history_html, agent_bubble_html(
          parse_agent_response(first_or(e$text, "(no reply)")),
          refs = refs))
        vals$stream <- ""
        vals$status <- "ready"
        vals$side_tick <- vals$side_tick + 1L
        shinyjs::enable("send")
      },
      error = {
        push_transient(note_html(paste0("Error: ", first_or(e$text, "?"))))
        vals$status <- "error"
        shinyjs::enable("send")
      },
      NULL)
  }

  # ---- file uploads -> background indexing ------------------------------------
  observeEvent(input$upload, {
    f <- input$upload
    req(f)
    if (!identical(vals$status, "ready")) {
      push_transient(note_html(
        "Already working - wait for the current job to finish."))
      return()
    }
    p <- chat_paths(cfg0$data_dir, vals$chat_id)
    dir.create(p$uploads, recursive = TRUE, showWarnings = FALSE)
    ok <- mapply(function(from, to) file.copy(from, to, overwrite = TRUE),
                 f$datapath, file.path(p$uploads, f$name))
    if (any(!ok)) {
      push_transient(note_html("Upload failed - could not copy a file."))
      return()
    }
    files_df <- data.frame(name = f$name,
                           path = file.path(p$uploads, f$name),
                           stringsAsFactors = FALSE)
    push_transient(note_html(paste0(
      "Uploaded: ", paste(f$name, collapse = ", "),
      " - indexing now...")))
    vals$status <- "indexing"
    vals$stage <- ""
    vals$events_file <- tempfile(fileext = ".jsonl")
    file.create(vals$events_file)
    vals$lines_done <- 0L
    shinyjs::disable("upload")
    bg_promise(index_worker, list(
      chat_id = vals$chat_id,
      files = files_df,
      env_path = env_path,
      project_dir = script_dir,
      events_file = vals$events_file
    ))$
      then(function(res) {
        # The 'indexed' or 'error' event already updated the UI; if the
        # worker died silently, recover the send button here.
        if (identical(vals$status, "indexing")) {
          vals$status <- "error"
          shinyjs::enable("upload")
          shinyjs::enable("send")
          push_transient(note_html(
            "Indexing ended unexpectedly - check the R console."))
        }
      })$
      catch(function(err) {
        push_transient(note_html(paste0(
          "Indexing error: ", conditionMessage(err))))
        vals$status <- "error"
        shinyjs::enable("upload")
        shinyjs::enable("send")
      })
  })

  # ---- sending a question -> one graph run ------------------------------------
  send_message <- function(msg) {
    msg <- trimws(msg)
    req(nzchar(msg))
    if (!identical(vals$status, "ready")) return()
    vals$history_html <- c(vals$history_html, user_bubble_html(msg))
    vals$status <- "thinking"
    vals$stream <- ""
    shinyjs::disable("send")
    vals$events_file <- tempfile(fileext = ".jsonl")
    file.create(vals$events_file)
    vals$lines_done <- 0L
    bg_promise(run_turn_worker, list(
      chat_id = vals$chat_id,
      question = msg,
      env_path = env_path,
      project_dir = script_dir,
      events_file = vals$events_file
    ))$
      then(function(final) {
        # The 'done' event normally finalizes the bubble; cover the race
        # where the promise resolves between polls.
        if (identical(vals$status, "thinking")) {
          handle_event(list(type = "done", text = final$content,
                            refs = final$refs))
        }
      })$
      catch(function(err) {
        push_transient(note_html(paste0(
          "Error: ", conditionMessage(err))))
        vals$status <- "error"
        shinyjs::enable("send")
      })
  }
  observeEvent(input$submit_msg, send_message(input$submit_msg))
  observeEvent(input$send, send_message(input$msg))

  # ---- new chat -----------------------------------------------------------------
  observeEvent(input$new_thread, {
    if (identical(vals$status, "thinking") ||
        identical(vals$status, "indexing")) return()
    new_id <- paste0("chat-", as.integer(Sys.time()),
                     sample.int(1e5, 1))
    session$sendCustomMessage("setChatId", new_id)
    # reload_chat() fires when input$chat_id updates.
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
