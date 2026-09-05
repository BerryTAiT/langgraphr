# langgraphr/R/dsl.R

<!-- TARGET: langgraphr/R/dsl.R -->

> The graph-authoring DSL: `lg_graph`, `lg_add_node`, `lg_add_edge`,
> `lg_set_memory`, `lg_compile`. Pure R functions that build a graph
> description and keep the R node functions on the R side.

```r
# dsl.R - the "full power of R" graph authoring surface.
#
# A developer writes, for example:
#   g <- lg_graph("demo", state = list(counter = list(type = "number")))
#   g <- g |> lg_add_node("inc", inc_fn)
#   g <- g |> lg_add_edge("inc", "inc")     # loop until fn ends it
#   graph <- lg_compile(g)
#   graph$invoke("start")
#
# Each node body is an R function(state) that returns
#   list(updates = list(...), goto = "node_id" or "__end__" or NULL)
# This keeps every piece of agent logic in R.

# lg_graph starts a new graph builder object.
lg_graph <- function(id, state = list(), entry = NULL) {
  # The graph id must be a simple string (used as server-side agent id).
  if (!is.character(id) || length(id) != 1L || !nzchar(id)) {
    cli::cli_abort("graph id must be a single non-empty string")
  }
  # Normalise and validate the state specification now (fail fast in R).
  state <- .lg_validate_state(state)
  # A private environment holds the R functions behind each node id.
  fns <- new.env(parent = emptyenv())
  # Build the builder object: a plain list carrying the description so far.
  structure(
    list(
      id = id,             # the graph id string
      state = state,       # normalised state spec (see schema.R)
      nodes = list(),      # ordered list of node descriptors
      edges = list(),      # list of list(from, to) default edges
      defaults = list(),   # named list: node -> its default next node
      entry = entry,       # the entry node id (may be NULL = first node)
      fns = fns            # environment mapping node id -> R function
    ),
    class = "lg_graph_builder"
  )
}

# lg_add_node attaches one node (an R function) to the graph builder.
lg_add_node <- function(builder, id, fn, description = "") {
  # The node id must be a non-empty string.
  if (!is.character(id) || length(id) != 1L || !nzchar(id)) {
    cli::cli_abort("node id must be a single non-empty string")
  }
  # The node body must be an R function.
  if (!is.function(fn)) cli::cli_abort("node '{id}': fn must be a function")
  # Node ids must be unique within a graph.
  if (id %in% names(builder$nodes)) {
    cli::cli_abort("duplicate node id '{id}'")
  }
  # Record the node descriptor (id + optional description).
  builder$nodes[[id]] <- list(id = id, description = description)
  # Store the R function in the private environment under this node id.
  assign(id, fn, envir = builder$fns)
  # If no entry node was chosen yet, make this first node the entry.
  if (is.null(builder$entry)) builder$entry <- id
  # Return the builder so calls can be piped with |>
  invisible(builder)
}

# lg_add_edge declares a DEFAULT edge from -> to.
# The default edge is followed when a node returns no goto.
lg_add_edge <- function(builder, from, to) {
  # Both endpoints must exist as nodes already.
  if (!from %in% names(builder$nodes)) cli::cli_abort("unknown node '{from}'")
  if (!to %in% names(builder$nodes)) cli::cli_abort("unknown node '{to}'")
  # Remember the edge in the edge list (kept for the graph spec).
  builder$edges[[length(builder$edges) + 1L]] <- list(from = from, to = to)
  # Remember the default successor for the "from" node.
  builder$defaults[[from]] <- to
  # Return the builder for piping.
  invisible(builder)
}

# lg_set_memory attaches optional persistence configuration to a graph.
# db_path (NULL = in-memory) sets the SQLite checkpoint path the server
# should use when this graph runs.
lg_set_memory <- function(builder, db_path = NULL) {
  # Store the database path on the builder (used by the compiler).
  builder$memory <- list(db_path = db_path)
  # Return the builder for piping.
  invisible(builder)
}

# lg_compile finalises the builder and registers the graph on the server.
lg_compile <- function(builder) {
  # Delegate all real work to the compiler (kept in compiler.R).
  .lg_compile_graph(builder)
}

# print method: make a builder print nicely in the console.
print.lg_graph_builder <- function(x, ...) {
  # Report the graph id and how many nodes/edges it currently has.
  cat("<lg_graph_builder> id:", x$id,
      "| nodes:", length(x$nodes),
      "| edges:", length(x$edges), "\n")
  # Return the builder invisibly so printing does not break pipes.
  invisible(x)
}
```
