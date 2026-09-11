# app.R - Data Detective Agent — Modern Web UI
#
# ChatGPT/Gemini-inspired interface with file upload, visualizations.
# Run: shiny::runApp("projects/data_detective/app.R")

library(shiny)
options(shiny.autoreload = FALSE)
options(shiny.minified = TRUE)

# ---- Setup ----------------------------------------------------------------

script_dir <- tryCatch({
  ofile <- NULL
  for (i in seq_len(sys.nframe())) {
    f <- sys.frame(i)$ofile
    if (!is.null(f)) { ofile <- f; break }
  }
  if (!is.null(ofile)) {
    d <- dirname(normalizePath(ofile, winslash = "/"))
  } else if (dir.exists("R")) {
    "."
  } else {
    file.path(dirname(getwd()), "data_detective")
  }
  if (dir.exists(file.path(d, "R"))) d else "."
}, error = function(e) {
  if (dir.exists("R")) "." else file.path(dirname(getwd()), "data_detective")
})

# Load project files
source(file.path(script_dir, "R", "modules_compat.R"), local = FALSE)
source(file.path(script_dir, "R", "tools.R"), local = FALSE)
source(file.path(script_dir, "R", "agent.R"), local = FALSE)

# Set app_dir for plot output
detective_state$app_dir <- script_dir

# Ensure plot directory exists
www_dir <- file.path(script_dir, "www")
plots_dir <- file.path(www_dir, "plots")
if (!dir.exists(plots_dir)) dir.create(plots_dir, recursive = TRUE)
detective_state$plot_dir <- plots_dir

# Load .env
env_candidates <- c(
  file.path(script_dir, ".env"),
  file.path(dirname(script_dir), "react_agent", ".env"),
  file.path(dirname(script_dir), "rag_chat", ".env"),
  file.path(dirname(script_dir), "r_chatbot", ".env")
)
env_path <- env_candidates[file.exists(env_candidates)][1]
if (!is.na(env_path) && file.exists(env_path)) {
  for (line in readLines(env_path, warn = FALSE)) {
    line <- trimws(line)
    if (!nzchar(line) || startsWith(line, "#")) next
    eq_pos <- regexpr("=", line)
    if (eq_pos > 0) {
      key <- trimws(substr(line, 1, eq_pos - 1))
      val <- trimws(substr(line, eq_pos + 1, nchar(line)))
      do.call(Sys.setenv, setNames(list(val), key))
    }
  }
}

if (!nzchar(Sys.getenv("LANGGRAPHR_API_KEY"))) {
  message("WARNING: LANGGRAPHR_API_KEY not set.\n  Searched: ",
          paste(env_candidates, collapse = ", "))
}

# Increase Shiny's upload limit (default is 5 MB — too small for real datasets)
options(shiny.maxRequestSize = 100 * 1024^2)  # 100 MB

# ---- UI -------------------------------------------------------------------

ui <- fluidPage(
  tags$head(
    tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"),
    tags$style(HTML(paste(readLines(file.path(script_dir, "www", "styles.css"), warn = FALSE), collapse = "\n"))),
    tags$link(rel = "preconnect", href = "https://fonts.googleapis.com"),
    tags$link(rel = "preconnect", href = "https://fonts.gstatic.com", crossorigin = ""),
    tags$link(href = "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap", rel = "stylesheet"),
    tags$script(HTML("
      function scrollChat() {
        var el = document.getElementById('chat_messages');
        if (el) el.scrollTop = el.scrollHeight;
      }
      $(document).on('keydown', '#user_input', function(e) {
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault();
          $('#btn_send').click();
        }
      });
      $(document).on('click', '.paperclip-btn', function(e) {
        e.preventDefault();
        $('#file_upload').click();
      });
    "))
  ),

  div(class = "app-shell",

    # ---- Main Chat Area (full width, no sidebar) ----
    div(class = "chat-area",

      # ---- Top bar ----
      div(class = "chat-topbar",
        div(class = "topbar-title", "Data Detective"),
        div(class = "topbar-sub", "Upload a CSV and ask anything about your data")
      ),

      # ---- Chat feed ----
      div(id = "chat_messages", class = "chat-feed"),

      # ---- Input area ----
      div(class = "input-area",
        div(class = "input-wrap",
          tags$label(
            `for` = "file_upload",
            class = "paperclip-btn",
            title = "Upload CSV",
            HTML("&#128206;")
          ),
          div(class = "file-hidden",
            fileInput("file_upload", label = NULL,
              accept = c(".csv", ".tsv", ".txt"),
              buttonLabel = "", placeholder = ""
            )
          ),
          # File chip — pure Shiny reactive UI, no JS
          uiOutput("file_chip_ui"),
          div(class = "text-flex",
            textInput("user_input", label = NULL,
              placeholder = "Ask about your data..."
            )
          ),
          actionButton("btn_send", label = "", class = "send-btn",
            icon = HTML("&#10148;"))
        )
      )
    )
  ),

  # Hidden inputs for server logic that still references sidebar outputs
  div(style = "display:none;",
    verbatimTextOutput("agent_status", placeholder = TRUE),
    uiOutput("ds_card"),
    uiOutput("checkpoint_display"),
    actionButton("btn_reset", "New Chat"),
    actionButton("btn_status", "Refresh")
  )
)

# ---- Server ---------------------------------------------------------------

server <- function(input, output, session) {

  # Create agent — use reactiveValues so renderUI re-runs when pending_file changes
  rv <- reactiveValues(
    agent = detective_agent(),
    msg_counter = 0,
    uploaded_file = NULL,
    pending_file = NULL
  )

  get_agent <- function() rv$agent

  # ---- File chip UI (reactive — re-runs when rv$pending_file changes) ----
  output$file_chip_ui <- renderUI({
    pf <- rv$pending_file
    if (is.null(pf)) return(NULL)
    div(class = "file-chip",
      span(class = "file-chip-icon", HTML("&#128206;")),
      span(class = "file-chip-name", pf$name),
      span(class = "file-chip-meta", sprintf("%dx%d", nrow(pf$df), ncol(pf$df))),
      actionButton("chip_remove", label = "", class = "file-chip-x",
        icon = HTML("&#10005;"))
    )
  })

  # ---- File upload handler ----
  observeEvent(input$file_upload, {
    req(input$file_upload)
    file_info <- input$file_upload
    file_path <- file_info$datapath

    # Read the CSV (pure R)
    df <- tryCatch({
      if (grepl("\\.csv$", file_info$name, ignore.case = TRUE)) {
        read.csv(file_path, stringsAsFactors = FALSE)
      } else {
        read.delim(file_path, stringsAsFactors = FALSE)
      }
    }, error = function(e) {
      showNotification(paste("Error reading file:", conditionMessage(e)),
                      type = "error", duration = 5)
      return(NULL)
    })

    if (is.null(df)) return()

    # Store as pending — the reactive renderUI will auto-render the chip
    rv$pending_file <- list(name = file_info$name, df = df)
  })

  # ---- Chip removed by user ----
  observeEvent(input$chip_remove, {
    rv$pending_file <- NULL
  })

  # ---- Send message ----
  observeEvent(input$btn_send, {
    msg <- trimws(input$user_input)
    has_pending <- !is.null(rv$pending_file)

    # If no text and no pending file, do nothing
    if (!nzchar(msg) && !has_pending) return()

    # If there's a pending file, load it now
    if (has_pending) {
      pf <- rv$pending_file
      load_data_frame(pf$df, pf$name)
      rv$uploaded_file <- pf$name
      rv$pending_file <- NULL  # reactive renderUI auto-clears the chip

      # Show file card in chat
      rv$msg_counter <- rv$msg_counter + 1
      insertUI(selector = "#chat_messages", where = "beforeEnd",
        ui = div(class = "msg msg-user",
          div(class = "msg-avatar user-av", "U"),
          div(class = "msg-content",
            div(class = "file-card",
              div(class = "file-icon", "&#128206;"),
              div(class = "file-info",
                div(class = "file-name", pf$name),
                div(class = "file-meta",
                  sprintf("%d rows x %d columns", nrow(pf$df), ncol(pf$df)))
              )
            )
          )
        )
      )
    }

    # Build the user message (if text provided)
    if (nzchar(msg)) {
      rv$msg_counter <- rv$msg_counter + 1
      insertUI(selector = "#chat_messages", where = "beforeEnd",
        ui = div(class = "msg msg-user",
          div(class = "msg-avatar user-av", "U"),
          div(class = "msg-content", div(class = "user-text", msg))
        )
      )
    }

    updateTextInput(session, "user_input", value = "")

    # Show thinking
    rv$msg_counter <- rv$msg_counter + 1
    thinking_id <- paste0("think_", rv$msg_counter)
    insertUI(selector = "#chat_messages", where = "beforeEnd",
      ui = div(id = thinking_id, class = "msg msg-assistant",
        div(class = "msg-avatar ai-av", "DD"),
        div(class = "msg-content",
          div(class = "thinking-dots",
            tags$span("Thinking"), " ",
            tags$span(class = "dots-anim", "..."))
        )
      )
    )

    # Build the message to send to the agent
    # If a file was just uploaded, tell the LLM about it
    agent_msg <- msg
    if (has_pending && nzchar(msg)) {
      agent_msg <- paste0(
        "I've uploaded a file called '", pf$name,
        "' (", nrow(pf$df), " rows, ", ncol(pf$df), " columns). ",
        msg
      )
    } else if (has_pending && !nzchar(msg)) {
      agent_msg <- paste0(
        "I've uploaded a file called '", pf$name,
        "' (", nrow(pf$df), " rows, ", ncol(pf$df),
        " columns). Analyze it for me — call column_info() and summary_stats(), ",
        "then explain what you find and suggest visualizations."
      )
    }

    # Run agent
    a <- get_agent()
    tmp_log <- tempfile(fileext = ".txt")
    result <- tryCatch({
      con <- file(tmp_log, open = "w")
      sink(con, type = "output")
      a$invoke(agent_msg)
    }, error = function(e) {
      paste0("Error: ", conditionMessage(e))
    }, finally = {
      try(sink(type = "output"), silent = TRUE)
      try(close(con), silent = TRUE)
    })
    tool_lines <- tryCatch(readLines(tmp_log, warn = FALSE), error = function(e) "")
    tool_log <- paste(tool_lines, collapse = "\n")
    try(unlink(tmp_log), silent = TRUE)

    removeUI(selector = paste0("#", thinking_id))

    # Show tool calls
    if (nzchar(tool_log) && grepl("\\[tool\\]", tool_log)) {
      rv$msg_counter <- rv$msg_counter + 1
      insertUI(selector = "#chat_messages", where = "beforeEnd",
        ui = div(class = "msg msg-assistant",
          div(class = "msg-avatar ai-av", "DD"),
          div(class = "msg-content",
            div(class = "tool-log", pre(tool_log))
          )
        )
      )
    }

    # Render response
    rv$msg_counter <- rv$msg_counter + 1
    render_assistant_message(result, paste0("msg_", rv$msg_counter))

    update_sidebar(a)
    session$onFlushed(function() session$sendCustomMessage("scrollChat", ""))
  })

  # ---- Clean markdown artifacts from LLM response ----
  clean_markdown <- function(text) {
    # Split into lines, process each, rejoin
    lines <- strsplit(text, "\n")[[1]]
    lines <- sapply(lines, function(line) {
      line <- sub("^#{1,6}\\s+", "", line)           # # heading -> heading
      line <- sub("^\\s*[-*]\\s+", "", line)           # - item -> item
      line <- sub("^\\s*\\d+\\.\\s+", "", line)         # 1. item -> item
      line <- sub("^\\s*>\\s*", "", line)              # > quote -> quote
      line
    })
    text <- paste(lines, collapse = "\n")
    # Inline formatting (multiline-safe)
    text <- gsub("\\*\\*(.+?)\\*\\*", "\\1", text)     # **bold** -> bold
    text <- gsub("(?<!\\*)\\*(?!\\*)", "", text, perl = TRUE)  # *italic* -> italic
    text <- gsub("__(.+?)__", "\\1", text)             # __bold__ -> bold
    text <- gsub("`(.+?)`", "\\1", text)               # `code` -> code
    text <- gsub("^---+$", "", text)                   # --- horizontal rule -> remove
    text <- gsub("\\[([^\\]]+)\\]\\([^\\)]+\\)", "\\1", text)  # [link](url) -> link
    # Remove stray emoji/icon unicode
    text <- gsub("[\U0001F300-\U0001F9FF]", "", text, perl = TRUE)
    text <- gsub("\\n{3,}", "\n\n", text)              # collapse blank lines
    trimws(text)
  }

  # ---- Render assistant message (parse [PLOT:...] and [TABLE:...] tags) ----
  render_assistant_message <- function(text, msg_id) {
    # Split text by [PLOT:...] and [TABLE:...] markers
    plot_pattern <- "\\[PLOT:([^\\]]+)\\]"
    table_pattern <- "\\[TABLE:([^\\]]+)\\]"
    dashboard_pattern <- "\\[DASHBOARD:([^\\]]+)\\]"

    # Find all markers and their positions
    markers <- gregexpr(paste0(plot_pattern, "|", table_pattern, "|", dashboard_pattern), text)
    matches <- regmatches(text, markers)[[1]]

    if (length(matches) == 0) {
      # No markers, just show cleaned text
      clean_text <- clean_markdown(text)
      insertUI(selector = "#chat_messages", where = "beforeEnd",
        ui = div(class = "msg msg-assistant",
          div(class = "msg-avatar ai-av", "DD"),
          div(class = "msg-content",
            div(class = "ai-text", HTML(gsub("\n", "<br>", clean_text)))
          )
        )
      )
      return()
    }

    # Split text into segments
    segments <- list()
    pos <- 1
    match_pos <- markers[[1]]
    match_lens <- attr(match_pos, "match.length")

    for (i in seq_along(matches)) {
      m <- matches[i]
      start <- match_pos[i]
      end <- match_pos[i] + match_lens[i] - 1

      # Text before the marker
      if (start > pos) {
        segments <- c(segments, list(list(
          type = "text",
          content = substr(text, pos, start - 1)
        )))
      }

      # The marker itself
      if (grepl(plot_pattern, m)) {
        plot_file <- sub(plot_pattern, "\\1", m)
        segments <- c(segments, list(list(
          type = "plot",
          file = plot_file
        )))
      } else if (grepl(table_pattern, m)) {
        segments <- c(segments, list(list(
          type = "table"
        )))
      } else if (grepl(dashboard_pattern, m)) {
        segments <- c(segments, list(list(
          type = "dashboard",
          count = sub(dashboard_pattern, "\\1", m)
        )))
      }

      pos <- end + 1
    }

    # Remaining text
    if (pos <= nchar(text)) {
      segments <- c(segments, list(list(
        type = "text",
        content = substr(text, pos, nchar(text))
      )))
    }

    # Build UI elements
    elements <- list()
    for (seg in segments) {
      if (seg$type == "text" && nzchar(trimws(seg$content))) {
        clean_seg <- clean_markdown(seg$content)
        if (nzchar(clean_seg)) {
          elements <- c(elements, list(
            div(class = "ai-text", HTML(gsub("\n", "<br>", clean_seg)))
          ))
        }
      } else if (seg$type == "plot") {
        plot_path <- file.path("plots", seg$file)
        elements <- c(elements, list(
          div(class = "plot-card",
            img(src = plot_path, class = "plot-img", onerror = "this.style.display='none'"),
            div(class = "plot-caption", seg$file)
          )
        ))
      } else if (seg$type == "table") {
        df <- detective_state$dataset
        if (!is.null(df)) {
          tbl_html <- build_table_html(head(df, 10))
          elements <- c(elements, list(
            div(class = "table-card", HTML(tbl_html))
          ))
        }
      } else if (seg$type == "dashboard") {
        # Dashboard renders as grid of all created plots
        plot_ids <- sapply(detective_state$plots_created, identity)
        if (length(plot_ids) > 0) {
          grid_items <- lapply(plot_ids, function(pid) {
            div(class = "dash-item",
              img(src = file.path("plots", paste0(pid, ".png")),
                  class = "dash-img",
                  onerror = "this.parentElement.style.display='none'")
            )
          })
          elements <- c(elements, list(
            div(class = "dashboard-grid", grid_items)
          ))
        }
      }
    }

    insertUI(selector = "#chat_messages", where = "beforeEnd",
      ui = div(id = msg_id, class = "msg msg-assistant",
        div(class = "msg-avatar ai-av", "DD"),
        div(class = "msg-content", elements)
      )
    )
  }

  # ---- Build HTML table ----
  build_table_html <- function(df) {
    hdr <- paste0("<th>", names(df), "</th>", collapse = "")
    body <- ""
    for (i in seq_len(nrow(df))) {
      cells <- sapply(df[i, ], function(v) {
        if (is.numeric(v)) sprintf("%.2f", v) else as.character(v)
      })
      body <- paste0(body, "<tr>", paste0("<td>", cells, "</td>", collapse = ""), "</tr>")
    }
    sprintf('<table class="data-table"><thead><tr>%s</tr></thead><tbody>%s</tbody></table>', hdr, body)
  }

  # ---- Sidebar updates ----
  update_sidebar <- function(a) {
    output$agent_status <- renderText({
      paste0("Model: ", a$model, "\n",
             "Messages: ", length(a$messages), "\n",
             "Steps: ", a$step, "\n",
             "Checkpoints: ", length(a$get_history()))
    })
    output$ds_card <- renderUI({
      if (is.null(detective_state$dataset)) {
        return(div(class = "ds-empty", "No dataset loaded"))
      }
      df <- detective_state$dataset
      div(class = "ds-card",
        div(class = "ds-name", detective_state$dataset_name %||% "data"),
        div(class = "ds-stats",
          span(class = "ds-stat", sprintf("%d rows", nrow(df))),
          span(class = "ds-stat", sprintf("%d cols", ncol(df)))
        ),
        div(class = "ds-cols", paste(names(df), collapse = ", "))
      )
    })
    output$checkpoint_display <- renderUI({
      cps <- a$get_history()
      if (length(cps) == 0) return(div(class = "cp-empty", "No checkpoints"))
      items <- lapply(seq_along(cps), function(i) {
        div(class = "cp-item",
          span(class = "cp-num", paste0("#", i)),
          span(class = "cp-step", paste0("Step ", cps[[i]]$metadata$step %||% 0))
        )
      })
      div(class = "cp-list", items)
    })
  }

  # ---- Initial render ----
  output$agent_status <- renderText("Initializing...")
  output$ds_card <- renderUI(div(class = "ds-empty", "No dataset loaded"))
  output$checkpoint_display <- renderUI(div(class = "cp-empty", "No checkpoints"))

  # Greeting
  observeEvent(TRUE, once = TRUE, {
    insertUI(selector = "#chat_messages", where = "beforeEnd",
      ui = div(class = "msg msg-assistant",
        div(class = "msg-avatar ai-av", "DD"),
        div(class = "msg-content",
          div(class = "ai-text",
            "Upload a CSV and ask me anything about it."
          )
        )
      )
    )
  })

  # ---- Reset ----
  observeEvent(input$btn_reset, {
    a <- get_agent()
    a$reset()
    detective_state$dataset <- NULL
    detective_state$dataset_name <- NULL
    detective_state$plot_count <- 0
    detective_state$plots_created <- list()
    rv$uploaded_file <- NULL
    removeUI(selector = "#chat_messages > *", multiple = TRUE)
    insertUI(selector = "#chat_messages", where = "beforeEnd",
      ui = div(class = "msg msg-assistant",
        div(class = "msg-avatar ai-av", "DD"),
        div(class = "msg-content",
          div(class = "ai-text", "Upload a CSV and ask me anything about it.")
        )
      )
    )
    update_sidebar(a)
  })

  # ---- Status refresh ----
  observeEvent(input$btn_status, {
    a <- get_agent()
    update_sidebar(a)
  })
}

# Helper for invoke_continuation (sends messages without adding user msg)
DataDetectiveAgent$set("public", "invoke_continuation", function(max_rounds = 10) {
  for (round in seq_len(max_rounds)) {
    self$step <- self$step + 1
    llm_messages <- c(list(list(role = "system", content = self$system_prompt)), self$messages)
    response <- langgraphr::lg_call_model(llm_messages, model = self$model)
    tool_calls <- lg_parse_tool_calls(response)

    if (length(tool_calls) == 0) {
      self$messages <- c(self$messages, list(list(role = "assistant", content = response)))
      self$checkpoint("final")
      return(response)
    }

    self$messages <- c(self$messages, list(list(role = "assistant", content = response)))

    tool_results <- character(0)
    for (call in tool_calls) {
      tool_name <- call$name
      args <- call$args %||% list()
      args <- args[!sapply(args, is.na)]
      cat(sprintf("\n  [tool] %s(%s)\n", tool_name,
                  paste(names(args), args, sep = "=", collapse = ", ")))
      result <- tryCatch({
        fn <- self$tools[[tool_name]]
        if (is.null(fn)) sprintf("Error: unknown tool '%s'", tool_name)
        else do.call(fn, args)
      }, error = function(e) sprintf("Error: %s", conditionMessage(e)))
      cat(sprintf("  [result] %s\n", substr(gsub("\n", " ", result), 1, 120)))
      tool_results <- c(tool_results, sprintf("Tool %s result:\n%s", tool_name, result))
    }

    self$messages <- c(self$messages, list(list(
      role = "user", content = paste(tool_results, collapse = "\n\n")
    )))
    self$checkpoint(sprintf("round_%d", round))
  }
  "I've reached the maximum number of tool calls."
}, overwrite = TRUE)

shinyApp(ui = ui, server = server, options = list(port = 8124))
