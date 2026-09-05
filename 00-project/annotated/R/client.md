# langgraphr/R/client.R

<!-- TARGET: langgraphr/R/client.R -->

> Low-level HTTP helpers, the NULL-coalescing operator, thread-id generator and
> the R-native model helper `lg_call_model()` (OpenAI-compatible REST).

```r
# client.R - low-level HTTP helpers + small utilities for langgraphr.
#
# Every call to the hidden server is JSON over HTTP to 127.0.0.1:<port>.
# Nothing in this file knows LangGraph internals; it only knows the
# HTTP contract documented in 00-project/06-api-contracts.md.

# ---- NULL / empty coalescing helper ---------------------------------------
# `%||%` returns the left value if it is not NULL and not empty,
# otherwise it returns the right (fallback) value. Base R has no
# built-in operator for this, so we define our own.
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L) y else x

# ---- URL construction ------------------------------------------------------
# .lg_url builds the full URL for one server endpoint.
# port = server port, path = endpoint path starting with "/".
.lg_url <- function(port, path) {
  # paste0 concatenates without spaces: "http://127.0.0.1:8123/health".
  paste0("http://127.0.0.1:", port, path)
}

# ---- Request builder -------------------------------------------------------
# .lg_req creates an httr2 request object for an endpoint.
# body is optional; when given it is sent as JSON with auto_unbox=TRUE,
# which keeps single scalars as JSON scalars (not 1-element arrays).
.lg_req <- function(port, path, body = NULL) {
  # Start a new request to the endpoint URL.
  req <- httr2::request(.lg_url(port, path))
  # Ask the server to send JSON back to us.
  req <- httr2::req_headers(req, Accept = "application/json")
  # Tell httr2 that HTTP 4xx/5xx are NOT automatic errors: .lg_perform
  # below reads the JSON body and raises a readable error that includes
  # the server's detail field (e.g. "Agent run failed: ...").
  req <- httr2::req_error(req, is_error = function(resp) FALSE)
  # If the caller supplied a body, attach it as a JSON request body.
  if (!is.null(body)) {
    req <- httr2::req_body_json(req, body, auto_unbox = TRUE)
  }
  # Return the fully-built request object.
  req
}

# ---- POST + error handling -------------------------------------------------
# .lg_perform sends a request and parses the JSON response.
# On any HTTP error it raises a clear cli error (R-facing, never Python).
.lg_perform <- function(port, path, body = NULL) {
  # Execute the request against the server.
  resp <- httr2::req_perform(.lg_req(port, path, body))
  # Read the HTTP status code (200 = success, 4xx/5xx = failure).
  status <- httr2::resp_status(resp)
  # Parse the response body from JSON into an R list.
  out <- httr2::resp_body_json(resp)
  # If the status indicates an error, abort with a helpful R message.
  if (status >= 400) {
    # Extract the server's detail field if present, otherwise its message.
    detail <- out$detail %||% out$message %||% "unknown server error"
    # FastAPI validation errors send detail as a list, not a string;
    # flatten any list into readable text so the user sees one clean line.
    if (is.list(detail)) {
      detail <- paste(unlist(detail, recursive = TRUE, use.names = FALSE),
                      collapse = "; ")
    }
    # Raise an R error; this message is what the user actually sees.
    cli::cli_abort(c(
      "langgraphr server error ({status}) on {path}",
      "x" = as.character(detail)
    ))
  }
  # Return the parsed response as an R list.
  out
}

# ---- GET + error handling --------------------------------------------------
# .lg_get performs a GET request and parses the JSON response.
.lg_get <- function(port, path) {
  # Execute the GET request (no body on a GET).
  resp <- httr2::req_perform(.lg_req(port, path))
  # Read the HTTP status code.
  status <- httr2::resp_status(resp)
  # Parse the JSON response body into an R list.
  out <- httr2::resp_body_json(resp)
  # Abort with a clear R error on any non-success status.
  if (status >= 400) {
    cli::cli_abort("langgraphr server error ({status}) on {path}")
  }
  # Return the parsed response.
  out
}

# ---- Thread ids ------------------------------------------------------------
# lg_thread_id generates a unique thread id. Thread ids are the memory key:
# reusing one id continues a conversation on the server's checkpointer.
lg_thread_id <- function() {
  # stamp = current time without separators, e.g. "20260904153012".
  stamp <- format(Sys.time(), "%Y%m%d%H%M%S")
  # rand = 6 random characters (letters or digits) for uniqueness.
  rand <- paste0(sample(c(letters, 0:9), 6, replace = TRUE), collapse = "")
  # Combine into one id string, e.g. "thread_20260904153012_ab3x9k".
  paste0("thread_", stamp, "_", rand)
}

# ---- R-native model helper ------------------------------------------------
# lg_call_model calls any OpenAI-compatible chat-completions API from R.
# This lets R graph nodes talk to an LLM directly (no Python involved).
lg_call_model <- function(messages,
                          model = NULL,
                          base_url = NULL,
                          api_key = NULL,
                          temperature = NULL,
                          max_tokens = NULL,
                          timeout = 120) {
  # Resolve the model name: argument, else env var, else a sensible default.
  model <- model %||% Sys.getenv("LANGGRAPHR_MODEL", unset = "gpt-4o-mini")
  # Resolve the base URL: argument, else env var, else OpenAI's default.
  base_url <- base_url %||% Sys.getenv("LANGGRAPHR_BASE_URL",
                                       unset = "https://api.openai.com/v1")
  # Resolve the API key: argument, else env var (also accept OPENAI_API_KEY).
  api_key <- api_key %||% Sys.getenv("LANGGRAPHR_API_KEY",
                                     unset = Sys.getenv("OPENAI_API_KEY", unset = ""))
  # The API key is required; abort early with a clear R message if missing.
  if (!nzchar(api_key)) {
    cli::cli_abort(paste0(
      "No API key found. Set LANGGRAPHR_API_KEY or OPENAI_API_KEY, ",
      "or pass api_key = ... ."
    ))
  }

  # Build the JSON body for the chat-completions endpoint.
  body <- list(model = model, messages = messages)
  # Add optional sampling parameters only when the caller supplied them.
  if (!is.null(temperature)) body$temperature <- temperature
  if (!is.null(max_tokens)) body$max_tokens <- max_tokens

  # Create the request: POST {base_url}/chat/completions with auth headers.
  req <- httr2::request(paste0(base_url, "/chat/completions"))
  # Attach the bearer token and tell the server we want JSON.
  req <- httr2::req_headers(req,
                            Authorization = paste("Bearer", api_key),
                            Accept = "application/json")
  # Attach the JSON body with auto_unbox so scalars stay scalars.
  req <- httr2::req_body_json(req, body, auto_unbox = TRUE)
  # Set a request timeout so a hung model call cannot freeze R forever.
  req <- httr2::req_timeout(req, seconds = timeout)

  # Perform the request; wrap so failures produce a readable R error.
  resp <- tryCatch(
    httr2::req_perform(req),                      # try the actual HTTP call
    error = function(e) {                         # if the call itself fails
      cli::cli_abort("Model request failed: {conditionMessage(e)}")
    }
  )
  # Parse the JSON response into an R list.
  parsed <- httr2::resp_body_json(resp)
  # If the provider returned an HTTP error, surface its message in R.
  if (httr2::resp_status(resp) >= 400) {
    cli::cli_abort("Model error: {parsed$error$message %||% 'unknown'}")
  }
  # Extract the assistant's reply text: choices[[1]]$message$content.
  parsed$choices[[1]]$message$content
}
```
