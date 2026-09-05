# multi_agent.R - the FULL-AUTHORING path: build agents as R graphs.
#
# This example needs NO model and NO API key. It shows:
#   1. the R DSL: lg_graph() |> lg_add_node() |> lg_add_edge()
#   2. node functions in pure R (state in, updates + goto out)
#   3. a loop written in R (goto back to the same node)
#   4. multi-agent: one graph calling another graph as a "tool"
# ---------------------------------------------------------------------------

# Load the package.
library(langgraphr)

# ==== Agent 1: a "countdown" graph written entirely in R ===================
# State has one overwrite channel (count) and one append channel (log).
countdown <- lg_graph(
  "countdown",
  state = list(
    count = list(type = "number", reducer = "overwrite", description = "counter"),
    log   = list(type = "list",   reducer = "append",    description = "steps")
  )
)

# This R function is the node body. It receives the current state.
count_step <- function(state) {
  # Read the current counter value (first call: parse the input text).
  n <- state$count
  # On the first visit the counter is not set yet, so parse the input text.
  if (is.null(n)) n <- as.numeric(state$input)
  # Lower the counter by one.
  n2 <- n - 1
  # If we still have steps left, loop back to this same node.
  if (n2 > 0) {
    # Return updates (new count + a log entry) and goto self to loop.
    list(updates = list(count = n2, log = paste0("tick ", n2)), goto = "step")
  } else {
    # Otherwise finish: no goto means the default edge (end) is used.
    list(updates = list(count = n2, log = "done"))
  }
}

# Assemble the countdown graph: one self-looping node.
countdown <- countdown |>
  lg_add_node("step", count_step, description = "count down one step")

# Register the graph on the hidden server; returns an LgGraph object.
countdown_graph <- lg_compile(countdown)

# Run the countdown starting from 3 (input becomes the state$input channel).
cr <- countdown_graph$invoke("3")
# Show what the graph produced.
cat("Countdown final state:", jsonlite::toJSON(cr$state, auto_unbox = TRUE), "\n")

# ==== Agent 2: an "orchestrator" that calls Agent 1 (multi-agent) ==========
# State for the orchestrator: one answer channel (overwrite).
orchestrator <- lg_graph(
  "orchestrator",
  state = list(answer = list(type = "str", reducer = "overwrite"))
)

# This node runs Agent 1 inside itself (an R graph calling another R graph).
run_countdown <- function(state) {
  # Invoke the countdown agent on a brand-new thread (fresh memory).
  sub <- countdown_graph$invoke(state$input, thread_id = lg_thread_id())
  # Read the sub-agent's final counter value from its final state.
  final_count <- sub$state$count
  # Read the step log recorded by the sub-agent.
  steps <- paste(sub$state$log, collapse = " -> ")
  # Build a human-readable summary string from the sub results.
  summary <- paste0("Countdown finished at ", final_count, "; steps: ", steps)
  # Return the summary as this node's state update; then end the graph.
  list(updates = list(answer = summary))
}

# Assemble the orchestrator: one node that delegates to Agent 1.
orchestrator <- orchestrator |>
  lg_add_node("run_sub_agent", run_countdown)

# Register and compile the orchestrator graph.
orchestrator_graph <- lg_compile(orchestrator)

# Run the orchestrator: it starts Agent 1 internally and reports back.
or <- orchestrator_graph$invoke("2")
cat("Orchestrator answer:", or$state$answer, "\n")
