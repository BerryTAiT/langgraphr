# agent.R — Code Reviewer Agent
# Pure R ReAct agent using langgraphr framework
# No Python server, no external packages

# ---- Clean markdown from LLM output for console ----
clean_markdown <- function(text) {
  if (is.null(text) || !nzchar(text)) return(text)

  lines <- strsplit(text, "\n")[[1]]
  lines <- sapply(lines, function(line) {
    line <- gsub("^```[a-zA-Z]*$", "", line)
    line <- gsub("^```$", "", line)
    line <- gsub("```", "", line)
    line <- gsub("\\*\\*(.+?)\\*\\*", "\\1", line, perl = TRUE)
    line <- gsub("(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", "\\1", line, perl = TRUE)
    line <- gsub("^#{1,6}\\s*", "", line, perl = TRUE)
    line <- gsub("^\\s*[-*]\\s+", "- ", line, perl = TRUE)
    line <- gsub("^\\s*\\d+\\.\\s+", "", line, perl = TRUE)
    line <- gsub("^>\\s*", "", line, perl = TRUE)
    line <- gsub("^---+$", "", line, perl = TRUE)
    line <- gsub("\\[([^]]+)\\]\\([^)]+\\)", "\\1", line, perl = TRUE)
    line <- gsub("`([^`]+)`", "\\1", line, perl = TRUE)
    trimws(line)
  })
  paste(lines[lines != "" | duplicated(lines)], collapse = "\n")
}

# ---- Agent R6 class ----
CodeReviewerAgent <- R6::R6Class("CodeReviewerAgent",
  public = list(
    model = NULL,
    system_prompt = NULL,
    messages = NULL,
    checkpointer = NULL,
    store = NULL,
    thread_id = NULL,
    tools = NULL,
    tool_descriptions = NULL,
    step = 0,
    checkpoints = NULL,
    verbose = FALSE,

    initialize = function(model = NULL, system_prompt = NULL, verbose = FALSE) {
      self$model <- model %||%
        Sys.getenv("LANGGRAPHR_MODEL", "deepseek-chat")
      self$verbose <- verbose
      self$system_prompt <- system_prompt %||% paste(
        "You are an R code reviewer.",
        "",
        "RESPONSE RULES:",
        "- Write in plain text. No markdown, no **bold**, no backticks, no code blocks.",
        "- Be concise. Say what's wrong, how to fix it, done.",
        "- Do NOT repeat yourself. Say it once clearly.",
        "- Do NOT greet. Do NOT say 'looks like' or 'it seems'.",
        "- If code is fine, say 'No issues found.' and stop.",
        "- Reference line numbers like 'Line 3:' not 'line number 3'.",
        "",
        "WORKFLOW:",
        "1. Call parse_check() first to verify syntax.",
        "2. Call find_functions() to understand structure.",
        "3. Call style_check() and security_check() for issues.",
        "4. Call complexity_check() if functions exist.",
        "5. Summarize findings in 3-5 sentences max.",
        "",
        "To call a tool, respond with ONLY this JSON:",
        '{"tool_calls": [{"name": "TOOL_NAME", "args": {"param": "value"}}]}',
        "",
        "When done with tools, write a plain text answer (no JSON, no markdown).",
        "",
        code_review_tool_descriptions()
      )
      self$messages <- list()
      self$checkpointer <- list()
      self$thread_id <- paste0("thread_", as.integer(runif(1, 1e6, 9e6)))
      self$tools <- code_review_tools()
      self$tool_descriptions <- code_review_tool_descriptions()
      invisible(self)
    },

    checkpoint = function(label = "step") {
      cp <- list(
        thread_id = self$thread_id,
        step = self$step,
        messages = self$messages,
        metadata = list(step = self$step, label = label,
                        timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
      )
      self$checkpoints <- c(self$checkpoints, list(cp))
      invisible(self)
    },

    get_history = function() { self$checkpoints },

    reset = function() {
      self$messages <- list()
      self$step <- 0
      self$checkpoints <- list()
      self$thread_id <- paste0("thread_", as.integer(runif(1, 1e6, 9e6)))
      invisible(self)
    },

    invoke = function(user_input, max_rounds = 10) {
      self$messages <- c(self$messages, list(list(
        role = "user", content = user_input
      )))

      for (round in seq_len(max_rounds)) {
        self$step <- self$step + 1

        llm_messages <- c(
          list(list(role = "system", content = self$system_prompt)),
          self$messages
        )

        response <- langgraphr::lg_call_model(llm_messages, model = self$model)

        tool_calls <- lg_parse_tool_calls(response)

        if (length(tool_calls) == 0) {
          cleaned <- clean_markdown(response)
          self$messages <- c(self$messages, list(list(
            role = "assistant", content = response
          )))
          self$checkpoint("final")
          return(cleaned)
        }

        self$messages <- c(self$messages, list(list(
          role = "assistant", content = response
        )))

        tool_results <- character(0)
        for (call in tool_calls) {
          tool_name <- call$name
          args <- call$args %||% list()
          args <- args[!sapply(args, is.na)]

          if (self$verbose) {
            cat(sprintf("  [tool] %s\n", tool_name))
          }

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

          if (self$verbose) {
            cat(sprintf("  [result] %s\n",
                        substr(gsub("\n", " ", result), 1, 100)))
          }

          tool_results <- c(tool_results, sprintf(
            "Tool %s result:\n%s", tool_name, result
          ))
        }

        self$messages <- c(self$messages, list(list(
          role = "user",
          content = paste(tool_results, collapse = "\n\n")
        )))

        self$checkpoint(sprintf("round_%d", round))
      }

      "Reached maximum tool call rounds."
    }
  )
)

code_reviewer_agent <- function(verbose = FALSE) {
  CodeReviewerAgent$new(verbose = verbose)
}
