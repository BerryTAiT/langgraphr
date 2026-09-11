# agent.R - Pure-R ReAct agent using langgraphr modules
#
# This agent does NOT go through the Python server. It uses:
#   - lg_call_model() from langgraphr (pure R, calls DeepSeek via httr2)
#   - LgInMemorySaver from checkpoint_ext.R (pure R checkpointing)
#   - LgInMemoryStore from store.R (pure R cross-thread memory)
#   - lg_checkpoint_metadata() for checkpoint metadata
#   - lg_checkpoint() / lg_checkpoint_tuple() for state snapshots
#
# The ReAct loop:
#   1. Build messages (system + history + user)
#   2. Call lg_call_model()
#   3. Parse tool calls from the response
#   4. If tool calls: execute tools, add results, checkpoint, go to 1
#   5. If no tool calls: return final answer

# Per-session state environment (holds the loaded dataset)
detective_state <- new.env(parent = emptyenv())
detective_state$dataset <- NULL

#' Create the Data Detective agent
#'
#' @param model Optional model name (defaults to LANGGRAPHR_MODEL env var)
#' @param system_prompt Optional system prompt override
#' @return An R6 DataDetectiveAgent object
detective_agent <- function(model = NULL, system_prompt = NULL) {
  DataDetectiveAgent$new(model = model, system_prompt = system_prompt)
}

# The agent R6 class
DataDetectiveAgent <- R6::R6Class("DataDetectiveAgent",
  public = list(
    model = NULL,
    system_prompt = NULL,
    messages = NULL,
    checkpointer = NULL,
    store = NULL,
    thread_id = NULL,
    step = 0,
    tools = NULL,
    tool_descriptions = NULL,

    initialize = function(model = NULL, system_prompt = NULL) {
      self$model <- model %||%
        Sys.getenv("LANGGRAPHR_MODEL", "deepseek-v4-flash")
      self$system_prompt <- system_prompt %||% paste(
        "You are a data analysis assistant. You help users explore datasets",
        "by calling tools to compute statistics, detect outliers, find correlations,",
        "compare groups, and create visualizations.",
        "",
        "CONVERSATION STYLE:",
        "- Be natural and conversational, like texting a knowledgeable friend.",
        "- DO NOT introduce yourself, say hello, or mention your name.",
        "- DO NOT start responses with phrases like 'I'd be happy to help' or 'Let me'.",
        "- Jump straight into the analysis or answer.",
        "- Keep it concise. No fluff, no filler, no preamble.",
        "- When you find something interesting, just say it directly.",
        "- If the user is conversational, be conversational back.",
        "- Remember the full conversation context — refer to earlier findings naturally.",
        "",
        "WORKFLOW:",
        "1. When a dataset is first available, call column_info() to understand its structure.",
        "2. Based on what the user wants, call the appropriate analysis or visualization tools.",
        "3. After getting tool results, explain what you found in natural language.",
        "4. Proactively suggest next steps (e.g., 'Want me to visualize this?').",
        "",
        "VISUALIZATION GUIDELINES:",
        "- User says 'bar chart of X' -> create_plot(type='bar', x='X')",
        "- User says 'scatter X vs Y' -> create_plot(type='scatter', x='X', y='Y')",
        "- User says 'distribution of X' -> create_plot(type='histogram', x='X')",
        "- User says 'boxplot of X by Y' -> create_plot(type='box', x='X', color='Y')",
        "- User says 'correlation heatmap' -> create_plot(type='heatmap')",
        "- User says 'pie chart of X' -> create_plot(type='pie', x='X')",
        "- User says 'show me the data' -> create_table()",
        "- User says 'dashboard' -> create_dashboard with multiple specs",
        "- If user doesn't specify, CHOOSE the best chart type based on the data",
        "",
        "RULES:",
        "1. Use the EXACT tool names listed below (case-sensitive).",
        "2. When you have gathered enough evidence, write your final answer in plain text (no JSON).",
        "3. Do NOT guess tool names. Only use the exact names from the list below.",
        "4. Do NOT wrap JSON in markdown code blocks. Output raw JSON only.",
        "",
        "To call a tool, respond with ONLY this JSON format:",
        '{"tool_calls": [{"name": "EXACT_TOOL_NAME", "args": {"param": "value"}}]}',
        "",
        "When you are done calling tools, respond with a plain text answer (no JSON).",
        "",
        "Available tools (use these EXACT names):",
        "  load_dataset(name) - Load a dataset ('iris','mtcars','airquality' or CSV path).",
        "  column_info() - Column types and completeness. No args.",
        "  summary_stats(columns) - Summary stats. columns is optional array of names.",
        "  detect_outliers(column) - Find outliers in a numeric column.",
        "  correlation_matrix(columns) - Pairwise correlations.",
        "  frequency_table(column) - Frequency table for a categorical column.",
        "  group_comparison(numeric_col, group_col) - Compare numeric across groups.",
        "  create_plot(type, x, y, color, bins, title) - Create visualization.",
        "    type: 'bar','line','scatter','histogram','box','pie','area','heatmap'",
        "    x, y, color: column names. title: optional.",
        "  create_table(columns, rows, title) - Show data as table.",
        "  create_dashboard(specs) - Multiple plots. specs=[{type,x,y,color,title},...]"
      )
      self$messages <- list()
      self$checkpointer <- LgInMemorySaver$new()
      self$store <- LgStore$new()
      self$thread_id <- langgraphr::lg_thread_id()
      self$tools <- detective_tools()
      self$tool_descriptions <- detective_tool_descriptions()
      invisible(self)
    },

    # Send a user message and run the ReAct loop
    invoke = function(user_input, max_rounds = 10) {
      # Add user message to history
      self$messages <- c(self$messages, list(list(
        role = "user", content = user_input
      )))

      # Run the tool-calling loop
      for (round in seq_len(max_rounds)) {
        self$step <- self$step + 1

        # Build full message list for the LLM
        llm_messages <- c(
          list(list(role = "system", content = self$system_prompt)),
          self$messages
        )

        # Call the LLM directly (pure R, no Python server)
        response <- langgraphr::lg_call_model(llm_messages, model = self$model)

        # Parse tool calls from the response
        tool_calls <- lg_parse_tool_calls(response)

        if (length(tool_calls) == 0) {
          # No tool calls = final answer
          self$messages <- c(self$messages, list(list(
            role = "assistant", content = response
          )))
          self$checkpoint("final")
          return(response)
        }

        # Add the assistant response to history (plain text, no tool_calls field)
        self$messages <- c(self$messages, list(list(
          role = "assistant",
          content = response
        )))

        # Execute each tool call and collect results
        tool_results <- character(0)
        for (call in tool_calls) {
          tool_name <- call$name
          args <- call$args %||% list()

          # Filter out NA args that the LLM might hallucinate
          args <- args[!sapply(args, is.na)]

          cat(sprintf("\n  [tool] %s(%s)\n",
                      tool_name,
                      paste(names(args), args, sep = "=", collapse = ", ")))

          result <- tryCatch({
            fn <- self$tools[[tool_name]]
            if (is.null(fn)) {
              sprintf("Error: unknown tool '%s'", tool_name)
            } else {
              do.call(fn, args)
            }
          }, error = function(e) {
            sprintf("Error: %s", conditionMessage(e))
          })

          cat(sprintf("  [result] %s\n",
                      substr(gsub("\n", " ", result), 1, 120)))

          tool_results <- c(tool_results, sprintf(
            "Tool %s result:\n%s", tool_name, result
          ))
        }

        # Add tool results as a user message (DeepSeek-compatible format)
        self$messages <- c(self$messages, list(list(
          role = "user",
          content = paste(tool_results, collapse = "\n\n")
        )))

        # Checkpoint after each round
        self$checkpoint(sprintf("round_%d", round))
      }

      # Safety: exceeded max rounds
      "I've reached the maximum number of tool calls. Here's what I found so far."
    },

    # Save a checkpoint using the InMemorySaver
    checkpoint = function(label = "") {
      cp <- lg_checkpoint(
        channel_values = list(
          messages = self$messages,
          step = self$step,
          thread_id = self$thread_id
        ),
        channel_versions = list(messages = self$step)
      )
      meta <- lg_checkpoint_metadata(
        source = "loop",
        step = self$step,
        run_id = label
      )
      config <- list(configurable = list(
        thread_id = self$thread_id,
        checkpoint_ns = ""
      ))
      self$checkpointer$put(config, cp, meta, list())
    },

    # Get the state snapshot from the checkpointer
    get_state = function() {
      config <- list(configurable = list(
        thread_id = self$thread_id,
        checkpoint_ns = ""
      ))
      tuple <- self$checkpointer$get_tuple(config)
      if (is.null(tuple)) return(NULL)
      tuple
    },

    # Get full checkpoint history
    get_history = function() {
      config <- list(configurable = list(
        thread_id = self$thread_id,
        checkpoint_ns = ""
      ))
      self$checkpointer$list(config)
    },

    # Rewind to a specific checkpoint and re-run from there
    rewind = function(checkpoint_id) {
      config <- list(configurable = list(
        thread_id = self$thread_id,
        checkpoint_ns = "",
        checkpoint_id = checkpoint_id
      ))
      tuple <- self$checkpointer$get_tuple(config)
      if (is.null(tuple)) {
        cat("Checkpoint not found.\n")
        return(invisible(NULL))
      }
      self$messages <- tuple$checkpoint$channel_values$messages
      self$step <- tuple$checkpoint$channel_values$step
      cat(sprintf("Rewound to checkpoint %s (step %d, %d messages)\n",
                  checkpoint_id, self$step, length(self$messages)))
      invisible(self)
    },

    # Store a cross-thread memory item
    remember = function(key, value) {
      self$store$put(
        namespace = c("detective", self$thread_id),
        key = key,
        value = value
      )
      cat(sprintf("Remembered: %s = %s\n", key, as.character(value)))
      invisible(self)
    },

    # Retrieve a cross-thread memory item
    recall = function(key) {
      self$store$get(
        namespace = c("detective", self$thread_id),
        key = key
      )
    },

    # Reset the conversation
    reset = function() {
      self$messages <- list()
      self$step <- 0
      self$thread_id <- langgraphr::lg_thread_id()
      detective_state$dataset <- NULL
      cat("Conversation reset. New thread:", self$thread_id, "\n")
      invisible(self)
    },

    # Print agent status
    print = function() {
      cat("=== Data Detective Agent ===\n")
      cat(sprintf("  model: %s\n", self$model))
      cat(sprintf("  thread: %s\n", self$thread_id))
      cat(sprintf("  messages: %d\n", length(self$messages)))
      cat(sprintf("  step: %d\n", self$step))
      checkpoints <- self$get_history()
      cat(sprintf("  checkpoints: %d\n", length(checkpoints)))
      cat(sprintf("  dataset loaded: %s\n",
                  if (!is.null(detective_state$dataset)) "yes" else "no"))
      invisible(self)
    }
  )
)
