# tour.R - lg_tour(): a guided, interactive tour of langgraphr's capabilities.
#
# The quickest way for a new user to understand what the package can do:
#   library(langgraphr); lg_tour()
# Pick a numbered demo from the menu; each one runs a small, self-contained
# example using built-in data. Demo 1 needs NO model or API key.

# The demo catalogue: one entry per capability, with a title and a runner.
.lg_tour_demos <- list(
  list(
    title = "Stateful graphs in pure R (NO model or API key needed)",
    run = function() {
      # A countdown graph whose nodes are R functions: loop via goto.
      countdown <- lg_graph("tour_countdown",
        state = list(
          count = list(type = "number", reducer = "overwrite"),
          log   = list(type = "list", reducer = "append")
        ))
      step <- function(state) {
        n <- state$count
        if (is.null(n)) n <- as.numeric(state$input)
        if (n - 1 > 0) {
          list(updates = list(count = n - 1, log = paste0("tick ", n - 1)),
               goto = "step")
        } else {
          list(updates = list(log = "done"))
        }
      }
      g <- countdown |> lg_add_node("step", step) |> lg_compile()
      res <- g$invoke("3")
      cat("Countdown final state:\n")
      str(res$state)
      cat("\nWhat just happened: LangGraph (real engine) ran a graph whose\n",
          "nodes are YOUR R functions. R paused/resumed over HTTP per node.\n")
    }
  ),
  list(
    title = "LLM assistant whose tools are YOUR R functions (needs API key)",
    run = function() {
      .lg_tour_need_key()
      sales <- data.frame(product = c("Aurora", "Nimbus", "Ember"),
                          revenue = c(120.5, 340.2, 95))
      top_n <- function(products, n = 2) {
        head(products[order(products$revenue, decreasing = TRUE), ,
                      drop = FALSE], n)
      }
      agent <- lg_connect()
      agent$add_tool(top_n,
        description = "Return the top-N products by revenue from a data frame")
      res <- agent$invoke(paste0(
        "Data: ", jsonlite::toJSON(sales, auto_unbox = TRUE),
        ". Use the tool to tell me the top 2 products by revenue."))
      cat("Assistant:", res$content, "\n")
      cat("\nWhat just happened: the LLM decided to call YOUR R function;\n",
          "it ran in this R session and the LLM used its real output.\n")
    }
  ),
  list(
    title = "Conversation memory across calls (needs API key)",
    run = function() {
      .lg_tour_need_key()
      agent <- lg_connect()
      r1 <- agent$invoke("My name is Berry and my favourite number is 7.")
      cat("Agent:", r1$content, "\n\n")
      r2 <- agent$invoke("What is my name, and what is my favourite number times 3?")
      cat("Agent:", r2$content, "\n")
      cat("\nWhat just happened: the same thread remembered the first turn.\n")
    }
  ),
  list(
    title = "RAG: retrieval + grounded generation, fully in R (needs API key)",
    run = function() {
      .lg_tour_need_key()
      corpus <- c(
        "langgraphr lets R developers build AI agents on the LangGraph engine.",
        "lg_connect() gives an assistant whose tools are R functions.",
        "lg_graph(), lg_add_node() and lg_compile() build stateful R-node graphs.",
        "Thread memory persists across calls; lg_use_sqlite() makes it durable."
      )
      # Tiny local retriever: score documents by keyword overlap.
      retrieve <- function(query, k = 2) {
        words <- tolower(strsplit(gsub("[^A-Za-z0-9 ]", " ", query), "\\s+")[[1]])
        words <- words[nchar(words) > 3]
        scores <- vapply(corpus, function(doc) {
          sum(vapply(words, function(w) grepl(w, tolower(doc), fixed = TRUE),
                     logical(1)))
        }, numeric(1))
        corpus[order(scores, decreasing = TRUE)][seq_len(min(k, length(corpus)))]
      }
      q <- "How do I build a graph with R node functions?"
      docs <- retrieve(q)
      cat("Question:", q, "\n")
      cat("Retrieved context:\n")
      cat(paste0("  - ", docs), sep = "\n")
      answer <- lg_call_model(list(
        list(role = "system", content = paste0(
          "Answer using ONLY this context. If it is insufficient, say so.\n\n",
          paste0("- ", docs, collapse = "\n"))),
        list(role = "user", content = q)
      ))
      cat("\nAnswer:", answer, "\n")
      cat("\nWhat just happened: retrieval ran locally in base R; only the\n",
          "grounded generation step used the model.\n")
    }
  ),
  list(
    title = "Where to go next (prints pointers, runs nothing)",
    run = function() {
      cat(paste0(
        "Capability map:\n",
        "  - Assistant with R tools .......... lg_connect() + $add_tool()\n",
        "  - Custom stateful graphs ......... lg_graph() / lg_add_node() / lg_compile()\n",
        "  - Multi-agent (graph calls graph). See examples/multi_agent.R\n",
        "  - Durable memory ................. lg_use_sqlite(path)\n",
        "  - Direct model calls from R ...... lg_call_model(messages)\n",
        "  - Shiny chat UI .................. agent_example/chat_app.R\n",
        "  - Chat with data via SQL ......... agent_example/data_agent.R\n",
        "  - Querychat-style data app ....... agent_example/data_chat_app.R\n",
        "  - RAG example .................... agent_example/rag_agent.R\n",
        "  - Docs ........................... ?lg_connect, ?lg_graph\n",
        "\nEverything is configured with env vars: LANGGRAPHR_MODEL,\n",
        "LANGGRAPHR_API_KEY, LANGGRAPHR_BASE_URL (optional, non-OpenAI).\n"))
    }
  )
)

# .lg_tour_need_key aborts a demo early with setup guidance when no model
# key is configured, instead of failing deep inside with a cryptic error.
.lg_tour_need_key <- function() {
  key <- Sys.getenv("LANGGRAPHR_API_KEY",
                    unset = Sys.getenv("OPENAI_API_KEY", unset = ""))
  if (!nzchar(key)) {
    cli::cli_abort(c(
      "This demo needs a model API key.",
      "i" = paste0("Set LANGGRAPHR_API_KEY (and optionally LANGGRAPHR_MODEL, ",
                   "LANGGRAPHR_BASE_URL), then re-run lg_tour()."),
      "i" = "Demo 1 (pure-R graphs) needs no key at all."
    ))
  }
  invisible(NULL)
}

#' Take a guided tour of langgraphr's capabilities
#'
#' Runs short, self-contained demonstrations of what the package can do,
#' using built-in data. Demo 1 (stateful R-node graphs) needs no model or
#' API key; the LLM demos need `LANGGRAPHR_API_KEY` (and optionally
#' `LANGGRAPHR_MODEL` / `LANGGRAPHR_BASE_URL`).
#'
#' @param demo Run a specific demo directly: `1` for pure-R graphs,
#'   `2` for the R-tools assistant, `3` for memory, `4` for RAG, `5` for
#'   the capability map. `NULL` shows an interactive menu.
#' @return `NULL`, invisibly. Demos print their output to the console.
#' @examples
#' \dontrun{
#' lg_tour()      # interactive menu
#' lg_tour(1)     # pure-R graph demo (no API key needed)
#' }
#' @export
lg_tour <- function(demo = NULL) {
  # Direct selection: run just that demo.
  if (!is.null(demo)) {
    demo <- as.integer(demo)
    if (is.na(demo) || demo < 1 || demo > length(.lg_tour_demos)) {
      cli::cli_abort("demo must be an integer between 1 and ",
                     "{length(.lg_tour_demos)}")
    }
    .lg_tour_run_one(demo)
    return(invisible(NULL))
  }

  # Interactive loop: menu until the user chooses to quit.
  repeat {
    cat("\n== langgraphr capability tour ==\n")
    for (i in seq_along(.lg_tour_demos)) {
      cat(" ", i, "-", .lg_tour_demos[[i]]$title, "\n")
    }
    cat(" ", length(.lg_tour_demos) + 1, "- Quit\n")
    pick <- suppressWarnings(as.integer(readline("Choose a demo: ")))
    if (is.na(pick) || pick == length(.lg_tour_demos) + 1L) {
      cat("Bye! (Re-run with lg_tour() any time.)\n")
      return(invisible(NULL))
    }
    if (pick >= 1 && pick <= length(.lg_tour_demos)) {
      .lg_tour_run_one(pick)
    }
  }
}

# .lg_tour_run_one executes one numbered demo with a header and error guard.
.lg_tour_run_one <- function(i) {
  d <- .lg_tour_demos[[i]]
  cat("\n---- Demo", i, ":", d$title, "----\n\n")
  # One failing demo must never crash the tour.
  tryCatch(d$run(), error = function(e) {
    cat("Demo failed:", conditionMessage(e), "\n")
  })
  cat("\n---- End of demo", i, "----\n")
  invisible(NULL)
}
