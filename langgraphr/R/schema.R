# schema.R - schemas and JSON transport helpers.
#
# The model only ever sees JSON schemas; R functions never cross the wire.
# Arguments arrive as JSON and are decoded into R values before a call,
# and results are converted back to JSON-safe R values afterwards.

# ---- Type guessing -----------------------------------------------------------
# .lg_type_guess maps an R default value to a JSON schema type name.
.lg_type_guess <- function(value, is_missing) {
  # A missing argument means "no default" -> we cannot infer, use string.
  if (isTRUE(is_missing)) return("string")
  # Logical defaults (TRUE/FALSE) map to the JSON boolean type.
  if (is.logical(value)) return("boolean")
  # Numeric defaults map to the JSON number type.
  if (is.numeric(value)) return("number")
  # Dates are represented as strings over the wire.
  if (inherits(value, "Date") || inherits(value, "POSIXt")) return("string")
  # Everything else (character, etc.) is treated as a string.
  "string"
}

#' Convert an R function into an OpenAI tool schema
#'
#' Builds the JSON schema the model needs to call an R function. Argument
#' types are inferred from default values; arguments without defaults are
#' marked required and typed as strings.
#'
#' @param fn The R function to expose as a tool.
#' @param name Tool name. Defaults to the function's own name.
#' @param description What the tool does (guidance for the model).
#' @param parameters An explicit JSON-schema `parameters` object; omit to
#'   infer the schema from the function's formal arguments.
#' @return A list in OpenAI tool-schema format.
#' @export
lg_tool_schema <- function(fn,
                           name = NULL,
                           description = "",
                           parameters = NULL) {
  # The tool must be a real function; abort otherwise.
  if (!is.function(fn)) cli::cli_abort("fn must be a function")
  # Default the tool name to the function's own name.
  if (is.null(name)) name <- deparse(substitute(fn))

  # If the caller did not supply an explicit parameter schema, infer one
  # from the function's formal arguments.
  if (is.null(parameters)) {
    # fmls = the function's formal arguments (name -> default expression).
    fmls <- formals(fn)
    # nms = the argument names in order.
    nms <- names(fmls)
    # properties will hold one entry per argument.
    properties <- list()
    # required collects the names of arguments that have no default.
    required <- character(0)

    # Loop over every formal argument.
    for (nm in nms) {
      # Skip special arguments like ... and pipes.
      if (nm %in% c("...", ".x")) next
      # A formal WITHOUT a default holds R's special "missing argument"
      # object. That object must NEVER be stored in a variable (using it
      # afterwards raises: argument "..." is missing); it can only be
      # compared inline. So we branch on the inline test first.
      if (identical(fmls[[nm]], quote(expr = ))) {
        # No default value exists: we cannot infer a type, so use string.
        properties[[nm]] <- list(type = "string", description = "")
        # Arguments without defaults are required in the schema.
        required <- c(required, nm)
      } else {
        # A default value exists and is safe to store and inspect now.
        default <- fmls[[nm]]
        # Record the JSON type guessed from that default value.
        properties[[nm]] <- list(
          type = .lg_type_guess(default, FALSE),
          description = ""
        )
      }
    }

    # Assemble the final parameters schema object.
    # An empty named list serializes as the JSON object {}; an unnamed
    # empty list would become the array [], which OpenAI rejects.
    if (length(properties) == 0L) names(properties) <- character(0)
    parameters <- list(
      type = "object",       # the argument container is a JSON object
      properties = properties # one property per function argument
    )
    # Only attach "required" when at least one argument is required.
    # I() protects the vector from jsonlite's auto_unbox (used by the HTTP
    # client), which would otherwise collapse a single-element required
    # array into a bare string and make the OpenAI API reject the schema.
    if (length(required) > 0L) parameters$required <- I(required)
  }

  # Return the full OpenAI-style tool schema (type = "function").
  list(
    type = "function",       # this schema describes a callable function
    # Note: "function" is a reserved word in R, so the name below is
    # backtick-quoted. It is a plain list key called "function" in JSON.
    `function` = list(
      name = name,               # tool name the model will emit in tool_calls
      description = description, # free text explaining what the tool does
      parameters = parameters    # the argument schema built above
    )
  )
}

# ---- Executing a tool call -----------------------------------------------------
# .lg_call_tool runs an R function with a decoded argument list.
.lg_call_tool <- function(fn, args) {
  # With no arguments, call the function with nothing.
  if (is.null(args) || length(args) == 0L) {
    fn()
  } else {
    # Otherwise expand the named argument list into the call.
    do.call(fn, args)
  }
}

# ---- JSON-safe results ----------------------------------------------------------
# .lg_prep_result makes any R value safe for JSON transport.
# Data frames become arrays of row objects (predictable encoding).
.lg_prep_result <- function(x) {
  # Data frames need special handling: one list entry per row.
  if (is.data.frame(x)) {
    # Convert each row to a named list, then collect them into a list.
    return(lapply(seq_len(nrow(x)), function(i) as.list(x[i, , drop = FALSE])))
  }
  # Lists are converted element-by-element (recursion).
  if (is.list(x)) return(lapply(x, .lg_prep_result))
  # Atomic values (numbers, strings, logicals) pass through unchanged.
  x
}

# ---- Argument coercion -----------------------------------------------------------
# .lg_coerce_args turns decoded-JSON tool arguments into natural R objects.
# The model sends JSON arrays; httr2 decodes them as unnamed lists, which
# breaks R tools that expect vectors or data frames (e.g. products$revenue
# silently returns NULL). We convert per argument:
#   unnamed list of objects  -> data frame (one row per object)
#   unnamed list of scalars  -> atomic vector
#   scalars / named lists    -> untouched (records stay records)
.lg_coerce_args <- function(args) {
  # Nothing to do without arguments.
  if (is.null(args) || length(args) == 0L) return(args)
  # Coerce each argument independently, preserving names and order.
  for (nm in names(args)) {
    args[[nm]] <- .lg_coerce_value(args[[nm]])
  }
  args
}

# .lg_coerce_value converts one JSON value to its natural R form.
.lg_coerce_value <- function(x) {
  # Scalars and named lists (JSON objects) mostly pass through, but a
  # single string that clearly contains a list of numbers (the model often
  # sends "1, 2, 3" or "[1, 2, 3]" for a vector argument, because the
  # inferred schema types unknown arguments as strings) becomes a numeric
  # vector so vector tools work as written.
  if (!is.list(x) || !is.null(names(x))) {
    if (is.character(x) && length(x) == 1L) {
      trimmed <- trimws(x)
      # JSON-array-looking string: parse it properly.
      if (grepl("^\\[.*\\]$", trimmed)) {
        parsed <- tryCatch(jsonlite::fromJSON(trimmed),
                           error = function(e) NULL)
        if (is.atomic(parsed) && !is.character(parsed)) return(as.numeric(parsed))
        if (is.character(parsed) && !anyNA(suppressWarnings(as.numeric(parsed)))) {
          return(as.numeric(parsed))
        }
      }
      # Comma/space-separated numbers: split and convert only when EVERY
      # token is numeric (never mangle ordinary text).
      tokens <- strsplit(gsub("[,;]+", " ", trimmed), "\\s+")[[1]]
      tokens <- tokens[nzchar(tokens)]
      if (length(tokens) > 1L) {
        nums <- suppressWarnings(as.numeric(tokens))
        if (!anyNA(nums)) return(nums)
      }
    }
    return(x)
  }
  # An empty JSON array stays an empty list.
  if (length(x) == 0L) return(x)
  # Are ALL elements objects (named lists)? Then treat as rows of a table.
  all_objects <- all(vapply(x, function(e) {
    is.list(e) && !is.null(names(e)) && !identical(names(e), "")
  }, logical(1)))
  if (all_objects) {
    # Align every row to the union of all column names, filling any
    # missing column with NA, then bind rows into one data frame.
    cols <- unique(unlist(lapply(x, names)))
    rows <- lapply(x, function(e) {
      missing_cols <- setdiff(cols, names(e))
      if (length(missing_cols) > 0L) {
        e[missing_cols] <- list(NA)
      }
      as.data.frame(e[cols], stringsAsFactors = FALSE)
    })
    return(do.call(rbind, rows))
  }
  # Mixed nested arrays: recurse into elements that are still arrays.
  nested <- vapply(x, is.list, logical(1))
  if (any(nested)) {
    x[nested] <- lapply(x[nested], .lg_coerce_value)
  }
  # Array of scalars: collapse into one atomic vector.
  unlist(x, recursive = FALSE)
}


# .lg_validate_state checks a user-supplied state spec and fills defaults.
# Returns a normalised list: field -> list(type, reducer, description).
.lg_validate_state <- function(state) {
  # Start with an empty normalised spec.
  out <- list()
  # Loop over every declared field name.
  for (nm in names(state)) {
    # Each field spec must itself be a list.
    spec <- state[[nm]]
    if (!is.list(spec)) cli::cli_abort("state field '{nm}' must be a list")
    # Default the type to "any" when not given.
    type <- spec$type %||% "any"
    # Default the reducer to "overwrite" when not given.
    reducer <- spec$reducer %||% "overwrite"
    # Only the two reducers we implement are allowed.
    if (!reducer %in% c("overwrite", "append")) {
      cli::cli_abort("state field '{nm}': reducer must be overwrite or append")
    }
    # Keep the description if provided, otherwise an empty string.
    desc <- spec$description %||% ""
    # Store the normalised field spec.
    out[[nm]] <- list(type = type, reducer = reducer, description = desc)
  }
  # Return the normalised state specification.
  out
}
