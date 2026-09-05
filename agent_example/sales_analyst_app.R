# sales_analyst_app.R - AI Sales Analyst: a modern chat-style UI.
#
# Chat sidebar on the right with real message bubbles (user right, agent
# left), suggestion chips, a collapsible data preview, and a pill input bar
# with a paperclip CSV button and circular send button. The chart fills the
# left area. Enter sends; Shift+Enter makes a new line.
#
# Run in the R console:
#   source("agent_example/sales_analyst_app.R")

# Load credentials. shiny::runApp() sets the working directory to this
# file's folder, so try both the repo-root-relative and sibling locations.
.env_file <- c("agent_example/.env", "../agent_example/.env")
.env_file <- .env_file[file.exists(.env_file)][1]
if (is.na(.env_file)) stop("agent_example/.env not found - create it with your LANGGRAPHR_* settings.")
dotenv::load_dot_env(.env_file)

suppressPackageStartupMessages({
  library(langgraphr)
  library(shiny)
  library(bslib)
  library(ggplot2)
})
if (!requireNamespace("shinyjs", quietly = TRUE)) install.packages("shinyjs")
library(shinyjs)

# ---- Tool factory -------------------------------------------------------------
.lg_sales_tools <- function(get_data, set_plot) {
  list(
    describe_data = function() {
      df <- get_data()
      paste0(capture.output(str(df)), collapse = "\n")
    },
    summarize_column = function(column) {
      df <- get_data()
      if (!column %in% names(df))
        return(paste0("Column '", column, "' not found. Columns: ",
                      paste(names(df), collapse = ", ")))
      x <- df[[column]]
      if (is.numeric(x)) {
        sprintf(paste0("Column '%s' (numeric, %d rows): min=%.2f, max=%.2f, ",
                       "mean=%.2f, median=%.2f, missing=%d"),
                column, length(x), min(x, na.rm = TRUE), max(x, na.rm = TRUE),
                mean(x, na.rm = TRUE), median(x, na.rm = TRUE), sum(is.na(x)))
      } else {
        tab <- sort(table(x, useNA = "ifany"), decreasing = TRUE)
        sprintf("Column '%s' (categorical). Top values:\n%s", column,
                paste(utils::capture.output(print(head(tab, 8))), collapse = "\n"))
      }
    },
    top_rows = function(by_column, n = 5) {
      df <- get_data()
      if (!by_column %in% names(df) || !is.numeric(df[[by_column]]))
        return(paste0("'", by_column, "' must be an existing numeric column."))
      top <- head(df[order(df[[by_column]], decreasing = TRUE), , drop = FALSE],
                  max(1, min(as.integer(n), 20)))
      paste(capture.output(print(top, row.names = FALSE)), collapse = "\n")
    },
    make_chart = function(x_column, y_column = NULL, chart_type = "bar") {
      df <- get_data()
      for (col in c(x_column, y_column)) {
        if (!is.null(col) && !col %in% names(df))
          return(paste0("Column '", col, "' not found. Columns: ",
                        paste(names(df), collapse = ", ")))
      }
      chart_type <- tolower(chart_type)
      acc <- "#2563EB"
      p <- if (identical(chart_type, "bar")) {
        ggplot(df, aes(.data[[x_column]])) +
          geom_bar(fill = acc) + theme_minimal(base_size = 13)
      } else if (identical(chart_type, "line")) {
        df_agg <- if (is.null(y_column)) {
          agg <- aggregate(rep(1, nrow(df)) ~ df[[x_column]], FUN = sum)
          names(agg) <- c(x_column, "count"); agg
        } else aggregate(df[[y_column]] ~ df[[x_column]], FUN = sum)
        names(df_agg)[1:2] <- c(x_column, if (is.null(y_column)) "count" else y_column)
        ggplot(df_agg, aes(x = .data[[x_column]], y = .data[[2]])) +
          geom_line(color = acc, linewidth = 1) + geom_point(color = acc) +
          theme_minimal(base_size = 13)
      } else if (identical(chart_type, "scatter") && !is.null(y_column)) {
        ggplot(df, aes(x = .data[[x_column]], y = .data[[y_column]])) +
          geom_point(alpha = .6, color = acc) + theme_minimal(base_size = 13)
      } else if (identical(chart_type, "histogram")) {
        ggplot(df, aes(.data[[x_column]])) +
          geom_histogram(bins = 30, fill = acc, color = "white") +
          theme_minimal(base_size = 13)
      } else return(paste0("Unknown chart_type '", chart_type,
                           "'. Use bar, line, scatter or histogram."))
      set_plot(p + labs(title = paste0(chart_type, ": ", x_column,
                       if (!is.null(y_column)) paste0(" vs ", y_column))) +
                 theme(plot.title = element_text(face = "bold")))
      invisible(paste0("Chart rendered: ", chart_type, " of ", x_column,
                       if (!is.null(y_column)) paste0(" vs ", y_column)))
    }
  )
}

# ---- Sample data --------------------------------------------------------------
.lg_sample_sales <- function(n = 200) {
  set.seed(42)
  data.frame(
    date     = seq(as.Date("2026-01-01"), by = "day", length.out = n),
    region   = sample(c("North", "South", "East", "West"), n, TRUE),
    category = sample(c("Electronics", "Clothing", "Home", "Sports"), n, TRUE),
    units    = sample(1:20, n, TRUE),
    revenue  = round(runif(n, 20, 900) * sample(1:20, n, TRUE), 2)
  )
}

# ---- Theme + custom CSS ---------------------------------------------------------
.theme <- bs_theme(preset = "shiny", bg = "#f4f6fb", fg = "#1e293b",
                   primary = "#2563EB")
.custom_css <- tags$style(HTML("
  html, body { height: 100%; margin: 0; overflow: hidden;
    background: #eef2f9; }
  /* ---- busy state: no grey fade, just a slim top progress bar ---- */
  :root { --_shiny-fade-opacity: 1; }
  [data-shiny-busy-spinners] .recalculating {
    --shiny-spinner-delay: 0s;
    --shiny-spinner-color: #2563EB;
  }
  /* ---- chat panel ---- */
  #chat-panel { background: #ffffff; border-left: 1px solid #e2e8f0;
    display: flex; flex-direction: column; height: 100vh; }
  .chat-header { padding: 14px 18px; border-bottom: 1px solid #e2e8f0;
    display: flex; align-items: center; gap: 10px; }
  .chat-avatar { width: 34px; height: 34px; border-radius: 10px;
    background: linear-gradient(135deg,#2563EB,#7C3AED); color: #fff;
    display: flex; align-items: center; justify-content: center;
    font-weight: 700; font-size: 15px; }
  .chat-title { font-weight: 700; font-size: 15px; margin: 0; }
  .chat-sub { font-size: 11px; color: #64748b; margin: 0; }
  /* ---- messages ---- */
  #msgs { flex: 1 1 auto; overflow-y: auto; padding: 16px 14px; }
  .msg { display: flex; margin-bottom: 12px; }
  .msg .bubble { max-width: 88%; padding: 10px 13px; border-radius: 16px;
    font-size: 13.5px; line-height: 1.45; white-space: pre-wrap;
    word-wrap: break-word; }
  .msg.agent .bubble { background: #f1f5f9; color: #1e293b;
    border-top-left-radius: 4px; }
  .msg.user { justify-content: flex-end; }
  .msg.user .bubble { background: #2563EB; color: #fff;
    border-top-right-radius: 4px; }
  .msg .who { font-size: 10.5px; color: #94a3b8; margin-bottom: 3px; }
  /* ---- suggestions ---- */
  .chips { display: flex; flex-wrap: wrap; gap: 6px; padding: 4px 14px 8px; }
  .chips .btn { border-radius: 999px; font-size: 12px; padding: 3px 12px; }
  /* ---- input pill ---- */
  .input-pill { margin: 0 14px 14px; padding: 8px; background: #f8fafc;
    border: 1px solid #e2e8f0; border-radius: 18px;
    display: flex; align-items: flex-end; gap: 6px; }
  .input-pill .form-control { border: none; background: transparent;
    box-shadow: none; font-size: 13.5px; padding: 6px 4px; }
  .input-pill .btn-send { width: 38px; height: 38px; border-radius: 50%;
    padding: 0; font-size: 16px; }
  .input-pill .btn-csv { border-radius: 999px; font-size: 12px; }
  .input-pill .shiny-input-container { margin-bottom: 0; }
  .input-pill label { display: none; }
  /* ---- chart side ---- */
  #chart-card { margin: 14px; height: calc(100vh - 28px);
    border-radius: 16px; box-shadow: 0 4px 18px rgba(15,23,42,.07);
    border: none; background: #fff; display: flex;
    flex-direction: column; }
  .chart-header { padding: 12px 16px; border-bottom: 1px solid #e2e8f0;
    display: flex; align-items: baseline; gap: 10px; }
  .chart-title { font-weight: 700; font-size: 15px; }
  .chart-sub { font-size: 11.5px; color: #64748b; }
  .chart-empty { color: #94a3b8; display: flex; height: 100%;
    align-items: center; justify-content: center; font-size: 14px; }
"))

# ---- Shiny UI -------------------------------------------------------------------
ui <- page(
  theme = .theme, shinyjs::useShinyjs(), .custom_css,
  title = "AI Sales Analyst",
  layout_columns(
    col_widths = c(8, 4),
    gap = 0,
    # ---- LEFT: chart filling the whole remaining area ----
    div(id = "chart-card",
        div(class = "chart-header",
            span(class = "chart-title", "Sales dashboard"),
            span(class = "chart-sub", id = "data-info", "sample data loaded")),
        div(class = "chart-body", style = "flex:1 1 auto; padding: 6px;",
            uiOutput("plot_ui"))),
    # ---- RIGHT: chat panel, full height ----
    div(id = "chat-panel",
        div(class = "chat-header",
            div(class = "chat-avatar", "AI"),
            div(h5(class = "chat-title", "Sales Analyst Agent"),
                p(class = "chat-sub", "powered by langgraphr")),
            div(style = "margin-left:auto;",
                actionButton("sample", "Sample data",
                             class = "btn-sm btn-outline-secondary"))),
        div(id = "msgs", uiOutput("msgs")),
        div(class = "chips",
            actionButton("ask1", "Which region earns the most?",
                         class = "btn-outline-primary"),
            actionButton("ask2", "Plot revenue by category",
                         class = "btn-outline-primary"),
            actionButton("ask3", "Top 5 sales",
                         class = "btn-outline-primary"),
            actionButton("ask4", "Summarize revenue",
                         class = "btn-outline-primary")),
        div(class = "input-pill",
            div(style = "flex:0 0 auto;",
                fileInput("csv", NULL, buttonLabel = icon("paperclip"),
                          placeholder = "", width = "60px")),
            div(style = "flex:1 1 auto;",
                textAreaInput("msg", NULL, placeholder = "Ask about your data...",
                              rows = 1, resize = "none")),
            actionButton("send", icon("paper-plane"),
                         class = "btn-send btn-primary")),
        tags$script(HTML("
          // Enter sends; Shift+Enter newline. We push the textarea's value
          // directly to Shiny (priority 'event') because textAreaInput only
          // syncs on blur by default, which made Enter appear to do nothing.
          $(document).on('keydown', '#msg', function(e){
            if (e.key === 'Enter' && !e.shiftKey){
              e.preventDefault();
              var v = $('#msg').val();
              if (v && v.trim()){
                Shiny.setInputValue('submit_msg', v, {priority: 'event'});
                $('#msg').val('');
              }
            }
          });
          // Keep the message area scrolled to the newest message
          $(document).on('shiny:value', function(){
            var m = document.getElementById('msgs');
            if (m) m.scrollTop = m.scrollHeight;
          });
        ")))
  )
)

# ---- Shiny server ---------------------------------------------------------------
server <- function(input, output, session) {
  sales_data <- reactiveVal(.lg_sample_sales())
  chart <- reactiveVal(NULL)
  # Transcript as a character vector of pre-rendered HTML message bubbles.
  msgs <- reactiveVal(character(0))

  agent <- reactiveVal(NULL)
  make_agent <- function() {
    a <- lg_connect()
    tools <- .lg_sales_tools(
      get_data = function() sales_data(),
      set_plot = function(p) chart(p)
    )
    a$add_tool(tools$describe_data,
               description = paste0("Show the structure of the current dataset: ",
                                    "column names, types and dimensions. Call this first."))
    a$add_tool(tools$summarize_column,
               description = paste0("Summarize one column by name (min/max/mean for ",
                                    "numeric, top values for categorical)."))
    a$add_tool(tools$top_rows,
               description = paste0("Return the top-N rows sorted by a numeric ",
                                    "column, e.g. highest revenue."))
    a$add_tool(tools$make_chart,
               description = paste0("Draw a chart for the user: chart_type is bar, ",
                                    "line, scatter or histogram; x_column is required, ",
                                    "y_column optional. ALWAYS call this when the user ",
                                    "asks for a plot/graph/visualization."))
    a
  }

  # Bubble renderer: escapes text and styles agent/user bubbles.
  bubble <- function(who, text) {
    esc <- htmlEscape(text)
    esc <- gsub("\n", "<br>", esc, fixed = TRUE)
    sprintf(paste0('<div class="msg %s"><div><div class="who">%s</div>',
                   '<div class="bubble">%s</div></div></div>'),
            who, if (who == "user") "You" else "Agent", esc)
  }

  output$msgs <- renderUI({
    div(style = "padding: 6px 2px;", HTML(paste(msgs(), collapse = "")))
  })

  output$plot_ui <- renderUI({
    if (is.null(chart())) {
      div(class = "chart-empty",
          "Ask the agent for a chart - it will appear here.")
    } else {
      plotOutput("plot", height = "100%")
    }
  })
  output$plot <- renderPlot({ req(chart()); chart() })

  # Data info line under the chart title.
  observeEvent(sales_data(), {
    df <- sales_data()
    shinyjs::html("data-info",
                  sprintf("%d rows, %d columns", nrow(df), ncol(df)))
  }, ignoreNULL = FALSE)

  # Send a message; show a thinking bubble, then the answer.
  send_message <- function(msg) {
    cat("DEBUG send_message received:", deparse(msg), "\n")
    msg <- trimws(msg); req(nzchar(msg))
    cat("DEBUG passed req() check\n")
    if (is.null(agent())) agent(make_agent())
    msgs(c(msgs(), bubble("user", msg), bubble("agent", "Thinking...")))
    res <- tryCatch(agent()$invoke(msg), error = function(e)
      list(content = paste("Error:", conditionMessage(e))))
    # Replace the trailing thinking bubble with the real answer.
    m <- msgs(); m[length(m)] <- bubble("agent", res$content)
    msgs(m)
  }

  # Enter in the textarea submits via the custom 'submit_msg' input
  # (pushed from JS with priority 'event', so it is never stale).
  observeEvent(input$submit_msg, send_message(input$submit_msg))
  # The Send button reads the textarea the ordinary way (blur syncs it).
  observeEvent(input$send, send_message(input$msg))
  observeEvent(input$ask1, send_message("Which region earns the most?"))
  observeEvent(input$ask2, send_message("Plot revenue by category"))
  observeEvent(input$ask3, send_message("Show me the top 5 sales by revenue"))
  observeEvent(input$ask4, send_message("Summarize the revenue column"))

  # Upload handler: read the CSV and rebuild the agent around it.
  observeEvent(input$csv, {
    req(input$csv$datapath)
    df <- tryCatch(read.csv(input$csv$datapath), error = function(e) NULL)
    if (is.null(df) || nrow(df) == 0) {
      showNotification("Could not read that CSV.", type = "error")
      return()
    }
    sales_data(df); agent(make_agent())
    msgs(c(msgs(), bubble("agent",
      sprintf("Loaded your file: %d rows, %d columns (%s). Ask me anything!",
              nrow(df), ncol(df), paste(names(df), collapse = ", ")))))
  })

  observeEvent(input$sample, {
    sales_data(.lg_sample_sales()); agent(make_agent())
    msgs(c(msgs(), bubble("agent", "Sample data loaded (200 rows).")))
  })
}

shinyApp(ui, server)
