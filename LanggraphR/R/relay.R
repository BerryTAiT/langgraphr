# relay.R - local LLM relay so the sidecar works on any network.
#
# Some VPN/proxy setups reset Python's TLS connections to the LLM API
# while R's own curl stack (which uses the OS TLS on Windows) still
# works. When the sidecar cannot reach the model, langgraphr starts a
# tiny HTTP relay inside THIS R process: the sidecar sends its OpenAI-
# style requests to the relay, and R forwards them with httr2/curl.
# This is fully automatic - the user never configures anything.

# .lg_start_relay launches (or returns) the local relay for a target API.
# Returns the relay's base URL, e.g. "http://127.0.0.1:8129".
.lg_start_relay <- function(target) {
  # Already running: reuse it (it may target a different base URL if the
  # user changed LANGGRAPHR_BASE_URL, so restart in that case).
  if (!is.null(.lg_env$relay)) {
    if (identical(.lg_env$relay$target, target)) {
      return(paste0("http://127.0.0.1:", .lg_env$relay$port))
    }
    .lg_stop_relay()
  }

  # Pick a free localhost port for the relay.
  port <- httpuv::randomPort(host = "127.0.0.1")
  # Trim trailing slashes so path joining is predictable.
  target <- sub("/+$", "", target)

  # The relay is a tiny Rook/httpuv app: forward everything verbatim.
  server <- httpuv::startServer("127.0.0.1", port, list(
    call = function(req) {
      # Rebuild the upstream URL from the incoming path and query.
      url <- paste0(target, req$PATH_INFO)
      if (nzchar(req$QUERY_STRING)) {
        url <- paste0(url, "?", req$QUERY_STRING)
      }
      # Read the full raw body of the request.
      body <- req$rook.input$read()
      # Forward the original headers minus hop-by-hop ones curl sets.
      hdrs <- req$HTTP_HEADERS
      hdrs <- hdrs[!names(hdrs) %in%
                     c("Host", "host", "Content-Length", "Connection")]
      # Perform the upstream request with R's curl (OS TLS stack).
      resp <- tryCatch(
        httr2::request(url) |>
          httr2::req_headers(!!!hdrs) |>
          httr2::req_body_raw(body, "application/json") |>
          httr2::req_error(is_error = function(resp) FALSE) |>
          httr2::req_timeout(seconds = 300) |>
          httr2::req_perform(),
        error = function(e) NULL
      )
      # Upstream failure: report a clean 502 back to the sidecar.
      if (is.null(resp)) {
        return(list(
          status = 502L,
          headers = list("Content-Type" = "application/json"),
          body = '{"detail":"relay could not reach the model API"}'
        ))
      }
      # Otherwise stream the upstream response straight back.
      list(
        status = httr2::resp_status(resp),
        headers = as.list(httr2::resp_headers(resp)),
        body = httr2::resp_body_raw(resp)
      )
    }
  ))

  # Remember the relay so it can be reused and stopped later.
  .lg_env$relay <- list(server = server, port = port, target = target)
  # Return the base URL the sidecar should use as LANGGRAPHR_BASE_URL.
  paste0("http://127.0.0.1:", port)
}

# .lg_stop_relay shuts the relay down (used on package unload).
.lg_stop_relay <- function() {
  if (!is.null(.lg_env$relay)) {
    try(httpuv::stopServer(.lg_env$relay$server), silent = TRUE)
    .lg_env$relay <- NULL
  }
  invisible(NULL)
}
