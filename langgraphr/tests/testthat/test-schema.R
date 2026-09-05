# Unit tests for the tool schema builder and thread-id helper.
# These tests need no server and no network.

test_that("lg_tool_schema builds an OpenAI-style schema", {
  # A function with one required arg, one defaulted, one logical default.
  fn <- function(df, n = 5, verbose = FALSE) df
  # Build its schema with an explicit name and description.
  s <- lg_tool_schema(fn, name = "top", description = "top n")

  # The top-level type must be "function" (OpenAI convention).
  expect_equal(s$type, "function")
  # The tool name must be what we passed. ("function" is a reserved word
  # in R, so it must be accessed with [[ ]] or backticks.)
  expect_equal(s[["function"]][["name"]], "top")
  # The description must be carried through.
  expect_equal(s[["function"]][["description"]], "top n")
  # Parameters must be an object schema.
  expect_equal(s[["function"]][["parameters"]]$type, "object")

  # Required = arguments WITHOUT defaults -> df only.
  required <- s[["function"]][["parameters"]]$required
  expect_true("df" %in% required)
  expect_false("n" %in% required)
  expect_false("verbose" %in% required)

  # Type inference from default values: n is a number, verbose a boolean.
  props <- s[["function"]][["parameters"]]$properties
  expect_equal(props$n$type, "number")
  expect_equal(props$verbose$type, "boolean")
})

test_that("lg_tool_schema defaults the name from the function", {
  # A plainly named function.
  my_fun <- function(x) x
  # Without an explicit name the function name must be used.
  s <- lg_tool_schema(my_fun)
  expect_equal(s[["function"]][["name"]], "my_fun")
})

test_that("explicit parameters win over inference", {
  # A function whose argument type we want to force.
  fn <- function(x) x
  # Supply a precise schema by hand.
  params <- list(type = "object",
                 properties = list(x = list(type = "number")))
  # Build the schema with the explicit parameters.
  s <- lg_tool_schema(fn, name = "f", parameters = params)
  # The returned schema must match exactly what we supplied.
  expect_identical(s[["function"]][["parameters"]], params)
})

test_that("required survives jsonlite auto_unbox as a JSON array", {
  # Regression: with auto_unbox = TRUE a single-element required vector
  # used to serialize as a bare string ("required": "products"), which the
  # OpenAI API rejected with "'products' is not of type 'array'".
  fn <- function(products, n = 3) products
  s <- lg_tool_schema(fn)
  # Serialize exactly the way the HTTP client does (httr2 uses these opts).
  json <- jsonlite::toJSON(s[["function"]][["parameters"]],
                           auto_unbox = TRUE)
  # The required list must stay a JSON array even with one element.
  expect_match(json, '"required"\\s*:\\s*\\[', fixed = FALSE)
  # And the unboxed string form must NOT appear.
  expect_false(grepl('"required"\\s*:\\s*"products"', json))
  # The type scalars, by contrast, must remain scalars.
  expect_match(json, '"type"\\s*:\\s*"number"')
})

test_that("tool arguments are coerced to natural R forms", {
  # Array of objects -> data frame with one row per object, columns typed.
  args <- .lg_coerce_args(list(products = list(
    list(product = "Aurora", revenue = 120.5),
    list(product = "Nimbus", revenue = 340.2)
  )))
  df <- args$products
  expect_s3_class(df, "data.frame")
  expect_equal(nrow(df), 2)
  expect_equal(df$revenue, c(120.5, 340.2))
  expect_equal(df$product, c("Aurora", "Nimbus"))

  # rbind fills missing columns with NA.
  args2 <- .lg_coerce_args(list(rows = list(
    list(a = 1), list(a = 2, b = "x")
  )))
  expect_equal(nrow(args2$rows), 2)
  expect_true(is.na(args2$rows$b[1]))

  # Array of scalars -> atomic vector (e.g. numbers for a stats tool).
  args3 <- .lg_coerce_args(list(numbers = list(120.5, 340.2, 95)))
  expect_type(args3$numbers, "double")
  expect_equal(args3$numbers, c(120.5, 340.2, 95))

  # Scalars and named lists (records) pass through untouched.
  args4 <- .lg_coerce_args(list(n = 3, opts = list(mode = "fast")))
  expect_equal(args4$n, 3)
  expect_identical(args4$opts, list(mode = "fast"))

  # Empty and NULL argument lists are returned unchanged.
  expect_identical(.lg_coerce_args(list()), list())
  expect_null(.lg_coerce_args(NULL))
})

test_that("zero-argument tools serialize properties as a JSON object", {
  # Regression: an empty unnamed list used to serialize as [] (array),
  # which OpenAI rejected with "[] is not of type object".
  fn <- function() "nothing to see"
  s <- lg_tool_schema(fn)
  json <- jsonlite::toJSON(
    .lg_name_empty_lists(s[["function"]][["parameters"]]),
    auto_unbox = TRUE)
  expect_match(json, '"properties"\\s*:\\s*\\{\\}')
  expect_false(grepl('"properties"\\s*:\\s*\\[', json))
})

test_that("proxy values are normalized to URLs", {
  # Plain host:port gains the http scheme.
  expect_equal(langgraphr:::.lg_normalize_proxy("127.0.0.1:11801"),
               "http://127.0.0.1:11801")
  # Full URL passes through.
  expect_equal(langgraphr:::.lg_normalize_proxy("http://127.0.0.1:11801"),
               "http://127.0.0.1:11801")
  # Per-scheme registry form picks https first, then http.
  expect_equal(langgraphr:::.lg_normalize_proxy("http=127.0.0.1:1;https=127.0.0.1:2"),
               "http://127.0.0.1:2")
  expect_equal(langgraphr:::.lg_normalize_proxy("http=127.0.0.1:1"),
               "http://127.0.0.1:1")
  # Unknown per-scheme form yields empty string.
  expect_equal(langgraphr:::.lg_normalize_proxy("ftp=x"), "")
})

test_that("numeric-looking strings become numeric vectors", {
  # Regression: the model often sends vector arguments as a single string
  # ("1, 2, 3" or "[1, 2, 3]") because unknown argument types are inferred
  # as strings; vector tools need real vectors.
  args <- .lg_coerce_args(list(
    numbers = "120.5, 340.2, 95, 210.8, 480.1",
    as_json = "[1, 2, 3]",
    text = "The quick brown fox",
    single = "42.5"
  ))
  expect_type(args$numbers, "double")
  expect_equal(args$numbers, c(120.5, 340.2, 95, 210.8, 480.1))
  expect_equal(args$as_json, c(1, 2, 3))
  # Ordinary text must stay a string.
  expect_identical(args$text, "The quick brown fox")
  # A single scalar string stays a scalar.
  expect_identical(args$single, "42.5")
})

test_that("thread ids are unique and prefixed", {
  # Generate several thread ids.
  ids <- replicate(5, lg_thread_id())
  # All five must be different from each other.
  expect_length(unique(ids), 5)
  # Each must start with the "thread_" prefix.
  expect_match(ids[[1]], "^thread_")
})
