# Unit tests for the graph-authoring DSL (structure only, no server).
# These tests never talk to the hidden server.

test_that("lg_graph builds a builder with normalised state", {
  # Create a graph with one field whose reducer defaults to overwrite.
  g <- lg_graph("g1", state = list(counter = list(type = "number")))
  # The object must carry the builder class.
  expect_s3_class(g, "lg_graph_builder")
  # The id must be stored.
  expect_equal(g$id, "g1")
  # The state spec must be normalised with a default description.
  expect_equal(g$state$counter$reducer, "overwrite")
  # The state spec must have the type we declared.
  expect_equal(g$state$counter$type, "number")
})

test_that("lg_add_node stores nodes and sets the first as entry", {
  # Build a graph and add two node functions.
  g <- lg_graph("g2") |>
    lg_add_node("first", function(state) list()) |>
    lg_add_node("second", function(state) list())
  # Both nodes must be recorded.
  expect_equal(names(g$nodes), c("first", "second"))
  # The entry must default to the first node added.
  expect_equal(g$entry, "first")
})

test_that("lg_add_edge records edges and defaults", {
  # Build a small graph with two nodes and one edge.
  g <- lg_graph("g3") |>
    lg_add_node("a", function(state) list()) |>
    lg_add_node("b", function(state) list()) |>
    lg_add_edge("a", "b")
  # The edge list must contain the a -> b pair.
  expect_equal(g$edges[[1]]$from, "a")
  expect_equal(g$edges[[1]]$to, "b")
  # The default successor of a must be b.
  expect_equal(g$defaults[["a"]], "b")
})

test_that("invalid inputs are rejected in R", {
  # An unknown reducer must fail immediately.
  expect_error(lg_graph("bad", state = list(x = list(reducer = "nope"))))
  # An edge to an unknown node must fail.
  expect_error(
    lg_graph("bad2") |>
      lg_add_node("a", function(state) list()) |>
      lg_add_edge("a", "ghost")
  )
  # A duplicate node id must fail.
  expect_error(
    lg_graph("bad3") |>
      lg_add_node("a", function(state) list()) |>
      lg_add_node("a", function(state) list())
  )
})
