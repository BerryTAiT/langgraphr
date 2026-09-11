# mock_model_server.R - a tiny local stand-in model for offline demos.
#
# Speaks just enough of the OpenAI chat-completions format for langgraphr.
# Every request carries the FULL message history, so this stateless stub
# "remembers" by reading that history - exactly how a real provider sees
# your conversation. When asked about the R environment it requests the
# session_info_tool R tool, which exercises the interrupt -> local tool ->
# resume path end to end.
#
# Run:  Rscript demo/mock_model_server.R     (listens on port 9911)

library(httpuv)
library(jsonlite)

# answer_for() decides the stub's reply from the last message and the
# history that the graph engine sends with every call.
answer_for <- function(msgs) {
  # The newest message drives the decision.
  last <- msgs[[length(msgs)]]
  # A tool message means the R tool already ran locally; report its result.
  if (identical(last$role, "tool")) {
    return(paste0("Here is your R environment: ", last$content))
  }
  text <- tolower(as.character(last$content %||% ""))
  # Flatten the whole history to lowercase for memory lookups.
  history <- tolower(paste(vapply(msgs, function(m) {
    c <- m$content
    if (is.character(c) && length(c) == 1L) c else ""
  }, character(1)), collapse = " "))
  # Tool request: hand control back to R (the interrupt path).
  if (grepl("environment|r setup", text)) {
    return(list(tool_calls = list(list(
      id = "call_env_1",
      type = "function",
      `function` = list(name = "session_info_tool", arguments = "{}")
    )), content = NULL))
  }
  # Memory answers, read straight out of the received history.
  if (grepl("favorite number", text) && grepl("42", history)) {
    return("You said your favorite number is 42.")
  }
  if (grepl("what's my name|who am i", text) && grepl("berry", history)) {
    return("Your name is Berry - nice to see you again!")
  }
  if (grepl("what's my name|who am i", text)) {
    return(paste0("I don't know your name yet - we're starting fresh! ",
                  "What should I call you?"))
  }
  if (grepl("my name is", text)) {
    return(paste0("Hi Berry! Nice to meet you - an R fan after my own ",
                  "heart. What are you working on today?"))
  }
  if (grepl("remember", text)) {
    return("Got it - your favorite number is 42. I'll keep that in mind, Berry.")
  }
  # Fallback.
  paste0("(offline demo model) You said: ", last$content)
}

app <- list(
  call = function(req) {
    # Only the chat-completions endpoint is implemented.
    if (!grepl("chat/completions", req$PATH_INFO)) {
      return(list(status = 404L, headers = list("Content-Type" = "text/plain"),
                  body = "not found"))
    }
    # Read and parse the request body (the full message history is in it).
    raw <- rawToChar(req$rook.input$read())
    body <- fromJSON(raw, simplifyVector = FALSE)
    reply <- answer_for(body$messages)
    # Wrap the reply in the OpenAI response shape (tool call or text).
    msg <- if (is.list(reply)) {
      list(role = "assistant", content = NULL, tool_calls = reply$tool_calls)
    } else {
      list(role = "assistant", content = reply)
    }
    out <- list(
      id = "chatcmpl-demo", object = "chat.completion", created = as.integer(Sys.time()),
      model = "offline-demo", choices = list(list(index = 0L, message = msg,
                                                  finish_reason = "stop")),
      usage = list(prompt_tokens = 0L, completion_tokens = 0L, total_tokens = 0L)
    )
    list(status = 200L,
         headers = list("Content-Type" = "application/json"),
         body = toJSON(out, auto_unbox = TRUE, null = "null"))
  }
)

cat("Offline demo model listening on http://127.0.0.1:9911/v1 ...\n")
startServer("127.0.0.1", 9911, app)
# Serve forever (until this R process is killed).
while (TRUE) service()
