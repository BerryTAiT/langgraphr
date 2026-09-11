# agent.R - connects the ReAct agent to langgraphr and runs its turn loop.
#
# Three pieces live here:
#   react_tool_defs()  - name -> description for every tool (shown in the
#                        sidebar badges and sent to the model)
#   make_react_tools() - the actual R functions, wired to the session
#                        upload folder and a per-session state environment
#   react_worker()     - ONE full agent turn, self-contained so it can run
#                        in a background R process: it reconnects to the
#                        thread, registers the tools, and drives the
#                        interrupt loop MANUALLY (instead of the package's
#                        built-in invoke()) so every tool call can be
#                        streamed to the UI as a REASON / ACT / OBSERVE
#                        event the moment it happens.

# react_tool_defs() - the single source of truth for tool descriptions.
react_tool_defs <- function() {
  list(
    get_weather =
      "Get live weather for any city",
    get_exchange_rate =
      paste0("Convert currency using live exchange rates ",
             "(use currency codes like USD, EUR)"),
    get_country_info =
      "Get facts about any country",
    read_data_file =
      "Read a CSV or Excel data file and return its contents",
    read_text_file =
      "Read a text or PDF file and return its contents",
    list_uploaded_files =
      "List files the user has uploaded in this session",
    summarize_dataframe =
      "Summarize a data frame with stats for each column"
  )
}

# relevant_tool_defs(msg) - pick only the tools this question could need.
# Registered tools are the only ones the model sees, so a weather question
# should not pay for seven tool schemas: fewer schemas means a smaller
# prompt and a faster first token. A plain chat question registers no
# tools at all and takes the fastest possible path.
relevant_tool_defs <- function(msg) {
  defs <- react_tool_defs()
  m <- tolower(msg)
  patterns <- c(
    get_weather =
      paste0("weather|temperature|forecast|rain|snow|humidity|wind|",
             "celsius|sunny|cloudy|hot|cold"),
    get_exchange_rate =
      paste0("exchange|currency|convert|\\busd\\b|\\beur\\b|\\bgbp\\b|",
             "\\bjpy\\b|\\bcny\\b|dollar|euro|yen|yuan|forex"),
    get_country_info =
      "countr|capital|population|language|region|continent",
    read_data_file =
      paste0("\\bcsv\\b|\\bxlsx?\\b|excel|spreadsheet|data ?(set|frame|",
             "file)|\\brows?\\b|\\bcolumns?\\b"),
    read_text_file =
      "\\bpdf\\b|text ?file|document|read.*file|file.*read",
    list_uploaded_files =
      "upload|attach|\\bfiles?\\b",
    summarize_dataframe =
      paste0("summar|statistic|\\bstats\\b|\\bmean\\b|median|",
             "distribution|analy[sz]e|overview"))
  keep <- names(patterns)[vapply(unname(patterns),
                                 function(p) grepl(p, m), logical(1))]
  # Any data/file intent also needs the supporting file tools, otherwise
  # the model could be told to load a file it has no tool for.
  if (any(c("summarize_dataframe", "read_data_file", "read_text_file")
          %in% keep)) {
    keep <- unique(c(keep, "read_data_file", "list_uploaded_files"))
  }
  if (length(keep) == 0L) return(defs[0])
  defs[keep]
}

# register_defs(msg, upload_files) - the tool set for one turn: the
# keyword match above, plus the file tools whenever the session has
# uploads, so short replies like "what does it say?" can still open the
# user's files. Registration uses add_tool(), the package's documented
# way to expose R functions to the model.
register_defs <- function(msg, upload_files = character(0)) {
  defs <- relevant_tool_defs(msg)
  if (length(upload_files) > 0L) {
    keep <- unique(c(names(defs), "read_data_file", "read_text_file",
                     "list_uploaded_files"))
    defs <- react_tool_defs()[keep]
  }
  defs
}

# make_react_tools(upload_dir, state) - build the tool functions for one
# session. `upload_dir` is where the UI saves uploaded files; `state` is a
# small environment that remembers the most recently loaded data frame so
# summarize_dataframe can analyze it without the model re-sending data.
make_react_tools <- function(upload_dir, state) {
  list(
    get_weather = get_weather,
    get_exchange_rate = get_exchange_rate,
    get_country_info = get_country_info,
    read_data_file = function(filepath) {
      r <- read_data_file(filepath, upload_dir)
      state$last_df <- r$df
      r$text
    },
    read_text_file = function(filepath) {
      read_text_file(filepath, upload_dir)
    },
    list_uploaded_files = function() {
      list_uploaded_files(upload_dir)
    },
    summarize_dataframe = function(data = NULL) {
      summarize_dataframe(data, upload_dir, state$last_df)
    }
  )
}

# react_worker(msg, thread_id, upload_dir, events_file, env_path,
#              source_dir) - one full agent turn, safe to run in a
# background process. The worker sources its own R/ files at startup
# (a fresh subprocess has none of the session's functions) and then
# drives the loop manually so each tool call can be logged live.
react_worker <- function(msg, thread_id, upload_dir, events_file,
                         env_path, source_dir, upload_files = character(0)) {
  # Fresh subprocess: load the project's own functions first.
  for (f in c("utils.R", "tools.R", "agent.R")) {
    source(file.path(source_dir, "R", f), local = TRUE)
  }
  library(langgraphr)
  # Load credentials (same pattern as the r_chatbot project).
  if (!is.null(env_path) && file.exists(env_path)) {
    try(dotenv::load_dot_env(env_path), silent = TRUE)
  }
  # Session state + tool functions + descriptions.
  state <- new.env(parent = emptyenv())
  state$last_df <- NULL
  # Register ONLY the tools plausibly needed for this question: fewer
  # tool schemas = smaller prompt = faster first token. A plain chat
  # question registers zero tools and takes the fastest path.
  defs <- register_defs(msg, upload_files)
  tools_all <- make_react_tools(upload_dir, state)
  tools <- tools_all[names(tools_all) %in% names(defs)]
  # Connect: the hidden server is started or reused; thread_id keys the
  # conversation memory on the server.
  agent <- lg_connect(thread_id = thread_id)
  for (nm in names(tools)) {
    agent$add_tool(tools[[nm]], name = nm, description = defs[[nm]])
  }
  # Start the run. The rest of this function is the assistant loop from
  # the package, driven manually so each tool call can be logged live.
  # .lg_perform_retrying adds automatic network-route fallback (direct vs
  # system proxy) when a connection drops mid-turn.
  res <- langgraphr:::.lg_perform_retrying(
    agent$port,
    paste0("/threads/", thread_id, "/runs"),
    list(input = as.character(msg), agent = "assistant"))
  # Safety cap: a runaway tool loop must not spin forever.
  rounds <- 0L
  while (identical(res$status, "interrupted")) {
    rounds <- rounds + 1L
    if (rounds > 15L) stop("Tool loop exceeded 15 rounds.")
    # Service every pending interrupt (usually exactly one).
    values <- lapply(res$interrupts, function(ic) {
      # REASON + ACT: what the model asked for, logged immediately.
      args <- if (is.null(ic$args)) list() else langgraphr:::.lg_coerce_args(ic$args)
      append_event(events_file, list(
        type = "act", tool = ic$name,
        args = format_args(args),
        reason = first_or(defs[[ic$name]], ""), t = now_stamp()))
      # Run the R function locally; errors become OBSERVE text so the
      # model can react instead of crashing the turn.
      out <- tryCatch(
        langgraphr:::.lg_prep_result(
          langgraphr:::.lg_call_tool(tools[[ic$name]], args)),
        error = function(e) {
          append_event(events_file, list(
            type = "error", tool = ic$name,
            text = conditionMessage(e), t = now_stamp()))
          paste0("Tool error: ", conditionMessage(e))
        })
      # OBSERVE: what the tool returned (also shown in the card).
      append_event(events_file, list(
        type = "observe", tool = ic$name,
        text = format_tool_result(out), t = now_stamp()))
      # Bonus for the demo: when a data file was just read, log its first
      # rows as a structured table the UI can render as a real <table>.
      if (identical(ic$name, "read_data_file") &&
          !is.null(state$last_df)) {
        preview <- head(state$last_df, 5)
        append_event(events_file, list(
          type = "table", tool = ic$name,
          cols = names(preview),
          rows = lapply(seq_len(nrow(preview)), function(i) {
            as.character(unlist(preview[i, ]))
          }), t = now_stamp()))
      }
      out
    })
    # Resume the run with the tool results (same network resilience).
    res <- langgraphr:::.lg_perform_retrying(
      agent$port,
      paste0("/threads/", thread_id, "/resume"),
      list(value = list(results = values)))
  }
  # DONE: the final answer, streamed as the last event.
  append_event(events_file, list(
    type = "done",
    text = first_or(res$content, "(no reply)"), t = now_stamp()))
  res
}
