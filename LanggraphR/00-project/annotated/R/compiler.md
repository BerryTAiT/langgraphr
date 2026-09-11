# langgraphr/R/compiler.R

<!-- TARGET: langgraphr/R/compiler.R -->

> Turns a DSL builder into a validated graph spec (plain R lists), POSTs it to
> the hidden server (`/graphs/register`) and returns an `LgGraph` object whose
> `nodes` map node ids to the R functions.

```r
# compiler.R - from DSL builder to a running LgGraph.
#
# The graph spec is JSON-serialisable, so the server (Python) can compile it
# into a real LangGraph StateGraph without ever seeing R code. The R node
# functions never leave this machine: they are executed here on interrupt.

# .lg_compile_graph is the internal workhorse behind lg_compile().
.lg_compile_graph <- function(builder) {
  # A builder is required.
  if (!inherits(builder, "lg_graph_builder")) {
    cli::cli_abort("lg_compile() expects an object from lg_graph()")
  }
  # There must be at least one node or the graph is meaningless.
  if (length(builder$nodes) == 0L) {
    cli::cli_abort("graph '{builder$id}' has no nodes")
  }

  # Determine the entry node: explicit choice, else the first node added.
  entry <- builder$entry %||% names(builder$nodes)[[1L]]
  # The entry node must actually exist.
  if (!entry %in% names(builder$nodes)) {
    cli::cli_abort("entry node '{entry}' does not exist")
  }

  # Collect the R functions for every node into a named list.
  node_fns <- as.list(builder$fns)   # environment -> named list of functions

  # Build the graph spec as plain R lists (JSON-serialisable).
  spec <- list(
    graph_id = builder$id,           # server-side id for this graph
    state = builder$state,           # normalised state spec
    nodes = unname(builder$nodes),   # ordered node descriptors (no names)
    entry = entry,                   # the entry node id
    edges = unname(builder$edges),   # default edges (list of from/to)
    defaults = builder$defaults      # node -> default next node
  )

  # Make sure the hidden server is running before registering the graph.
  lg_start_server()
  # Register the spec; the server compiles it into a real StateGraph.
  out <- .lg_perform(.lg_connect_port(), "/graphs/register",
                     list(spec = spec))
  # The server answers with the registered graph id.
  graph_id <- out$graph_id

  # Return a ready-to-run LgGraph bound to this graph and its R functions.
  LgGraph$new(port = .lg_connect_port(), graph_id = graph_id,
              thread_id = NULL, nodes = node_fns)
}

# .lg_connect_port returns the effective server port for this session.
.lg_connect_port <- function() {
  # The port is whatever the package option says (default 8123).
  getOption("langgraphr.port", 8123L)
}
```
