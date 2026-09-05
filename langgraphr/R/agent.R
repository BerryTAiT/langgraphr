# agent.R - LgAgent and LgGraph: the objects developers use.
#
# LgAgent  : the quick path. A bundled LangGraph assistant whose tools are
#            R functions. invoke() drives the tool loop via interrupts.
# LgGraph  : the full-authoring path. Runs a graph the user described with
#            the DSL (dsl.R) and compiled via compiler.R. Node bodies are
#            R functions; their return values (goto/updates) drive the run.
#
# Both work over the same HTTP contract and the same idea: when the server
# needs R code, it interrupts the run and we resume after running it.

#' Connect to the hidden LangGraph server (assistant path)
#'
#' Starts the hidden Python server if it is not already running and returns
#' an [LgAgent]: a bundled assistant whose tools are plain R functions you
#' register with `$add_tool()`. Conversation memory is keyed by `thread_id`.
#'
#' @param port Port for the hidden server (default from the
#'   `langgraphr.port` option, otherwise 8123).
#' @param thread_id Reuse an existing thread id to continue a conversation;
#'   `NULL` generates a fresh one.
#' @return An [LgAgent] object.
#' @examples
#' \dontrun{
#' agent <- lg_connect()
#' agent$add_tool(my_function, description = "What my_function does")
#' res <- agent$invoke("Hello!")
#' res$content
#' }
#' @export
lg_connect <- function(port = getOption("langgraphr.port", 8123L),
                       thread_id = NULL) {
  # Make sure the hidden server is running before we build an agent.
  lg_start_server(port = port)
  # Create a new agent object bound to this port and thread.
  LgAgent$new(port = port, thread_id = thread_id)
}

# ---- LgAgent: quick assistant path ----------------------------------------------
# LgAgent is an R6 class: it keeps state (port, thread, tools) and methods.
LgAgent <- R6::R6Class(
  "LgAgent",
  public = list(
    # @field port - which port the hidden server listens on.
    port = NULL,
    # @field thread_id - the memory key for this conversation.
    thread_id = NULL,
    # @field tools - named list of registered R tool functions.
    tools = NULL,
    # @field agent_id - which server-side agent type to run.
    agent_id = NULL,

    # Constructor: called by lg_connect() (and directly by power users).
    initialize = function(port, thread_id = NULL, agent_id = "assistant") {
      # Remember which port to talk to.
      self$port <- port
      # Remember which server-side agent to run.
      self$agent_id <- agent_id
      # Use the caller's thread id or generate a fresh one.
      self$thread_id <- thread_id %||% lg_thread_id()
      # Start with an empty tool registry.
      self$tools <- list()
      # Return the object invisibly for chaining.
      invisible(self)
    },

    # add_tool registers an R function as a tool the assistant may call.
    add_tool = function(fn, name = NULL, description = "",
                        parameters = NULL) {
      # Resolve the tool name HERE (not later): substitute(fn) inside this
      # method sees the real expression the user passed, e.g. "top_products".
      # Doing it further down (inside lg_tool_schema) would only see the
      # parameter name "fn", which would register a tool literally named "fn".
      if (is.null(name)) name <- deparse(substitute(fn))
      # Build the OpenAI-style schema for this R function.
      schema <- lg_tool_schema(fn, name = name,
                               description = description,
                               parameters = parameters)
      # Extract the resolved tool name from the schema. ("function" is a
      # reserved word in R, so we access the key with [[ ]].)
      tname <- schema[["function"]][["name"]]
      # POST the schema to the server's tool registry.
      .lg_perform(self$port, "/tools/register", list(
        name = tname,                       # tool name the model will see
        description = schema[["function"]][["description"]], # what it does
        parameters = schema[["function"]][["parameters"]]    # arg schema
      ))
      # Remember the R function locally, keyed by tool name.
      self$tools[[tname]] <- fn
      # Return the agent so add_tool can be chained.
      invisible(self)
    },

    # invoke sends one message and drives the tool loop to completion.
    invoke = function(input, max_rounds = 10L) {
      # POST a new run on this thread; recovery restarts the sidecar on
      # an alternate route (direct <-> system proxy) on connection errors.
      result <- .lg_perform_retrying(
        self$port,
        paste0("/threads/", self$thread_id, "/runs"),
        list(input = as.character(input),
             agent = self$agent_id))
      # Count how many tool rounds we have done (safety cap).
      rounds <- 0L
      # Keep looping while the server asks us to run R tools.
      while (identical(result$status, "interrupted")) {
        # Increase the round counter each time we service interrupts.
        rounds <- rounds + 1L
        # Abort if the agent is stuck in a tool loop.
        if (rounds > max_rounds) {
          cli::cli_abort("Tool loop exceeded {max_rounds} rounds.")
        }
        # Run every requested R tool locally, keeping request order.
        values <- lapply(result$interrupts, function(ic) {
          # Look up the R function registered for this tool name.
          fn <- self$tools[[ic$name]]
          # The server asked for a tool we never registered: abort.
          if (is.null(fn)) {
            cli::cli_abort("Server requested unknown tool '{ic$name}'.")
          }
          # Decode the arguments (already an R list from JSON parsing) and
          # coerce JSON arrays into natural R forms (vectors, data frames).
          args <- if (is.null(ic$args)) list() else ic$args
          args <- .lg_coerce_args(args)
          # Call the R function and make the result JSON-safe.
          .lg_prep_result(.lg_call_tool(fn, args))
        })
        # Resume the interrupted run with the tool results.
        result <- .lg_perform_retrying(
          self$port,
          paste0("/threads/", self$thread_id, "/resume"),
          list(value = list(results = values))
        )
      }
      # Return the final run result (completed) to the caller.
      result
    },

    # reset forgets this conversation by switching to a new thread id.
    reset = function() {
      # A brand new thread id means a brand new (empty) conversation.
      self$thread_id <- lg_thread_id()
      # Return the agent invisibly for chaining.
      invisible(self)
    }
  )
)

# ---- LgGraph: full-authoring path ------------------------------------------------
# LgGraph runs a compiled R-authored graph on the server.
LgGraph <- R6::R6Class(
  "LgGraph",
  public = list(
    # @field port - server port.
    port = NULL,
    # @field graph_id - the server-side id of this graph.
    graph_id = NULL,
    # @field thread_id - current memory/run thread.
    thread_id = NULL,
    # @field nodes - named list of the R functions behind each node.
    nodes = NULL,

    # Constructor: created by lg_compile() in compiler.R.
    initialize = function(port, graph_id, thread_id = NULL, nodes = list()) {
      # Remember the server port.
      self$port <- port
      # Remember the registered graph id on the server.
      self$graph_id <- graph_id
      # Use the caller's thread id or make a fresh one.
      self$thread_id <- thread_id %||% lg_thread_id()
      # Keep the R node functions so we can run them on interrupts.
      self$nodes <- nodes
      # Return the object invisibly.
      invisible(self)
    },

    # invoke starts a run of this graph with the given input text.
    invoke = function(input, thread_id = NULL, max_rounds = 100L) {
      # Allow an explicit thread id per call (overrides the stored one).
      if (!is.null(thread_id)) self$thread_id <- thread_id
      # POST a run of this graph on the thread (with connection recovery).
      result <- .lg_perform_retrying(
        self$port,
        paste0("/threads/", self$thread_id, "/runs"),
        list(input = as.character(input),
             agent = self$graph_id))
      # Count interrupt-service rounds (safety cap).
      rounds <- 0L
      # Service interrupts until the graph run completes.
      while (identical(result$status, "interrupted")) {
        # Increment the round counter.
        rounds <- rounds + 1L
        # Guard against runaway graphs (e.g. an accidental infinite loop).
        if (rounds > max_rounds) {
          cli::cli_abort("Graph run exceeded {max_rounds} node rounds.")
        }
        # Prepare the resume reply for the pending node interrupt(s).
        # Linear graphs produce exactly one pending interrupt per stop.
        if (length(result$interrupts) > 1L) {
          # Multiple concurrent interrupts are a roadmap feature (parallel
          # Send); we currently only service the first one safely.
          cli::cli_alert_warning(paste0(
            "Multiple pending node interrupts (",
            length(result$interrupts), "); servicing the first only."
          ))
        }
        # Take the first (and normally only) pending node interrupt.
        ic <- result$interrupts[[1]]
        # Look up the R function registered for this node id.
        fn <- self$nodes[[ic$node]]
        # A node id we do not know means the R and server specs disagree.
        if (is.null(fn)) {
          cli::cli_abort("Server requested unknown node '{ic$node}'.")
        }
        # Call the node function with the current state it was given.
        out <- .lg_call_tool(fn, list(state = ic$state))
        # A node result is a list; normalise it to list(updates, goto).
        out <- out %||% list()
        # Extract the optional goto target (NULL = follow default edge).
        goto <- out$goto %||% NULL
        # Extract the optional state updates (may be NULL/empty).
        updates <- out$updates %||% list()
        # Resume the graph with exactly the reply shape the bridge expects.
        result <- .lg_perform_retrying(
          self$port,
          paste0("/threads/", self$thread_id, "/resume"),
          list(value = list(reply = list(goto = goto, updates = updates)))
        )
      }
      # Return the completed run result (includes final state).
      result
    },

    # reset moves this graph object to a fresh thread.
    reset = function() {
      # New thread id = fresh memory and run history.
      self$thread_id <- lg_thread_id()
      # Return the graph invisibly.
      invisible(self)
    }
  )
)
