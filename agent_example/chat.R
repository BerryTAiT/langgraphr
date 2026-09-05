# chat.R - interactive console chat with the langgraphr agent.
#
# Usage (in the R console):
#   source("agent_example/chat.R")
#   lg_chat(agent)        # or just lg_chat() to connect fresh
#
# Type your message and press Enter. Type "quit" (or press Esc) to stop.

lg_chat <- function(agent = NULL) {
  # Connect (or reuse the passed agent) when needed.
  if (is.null(agent)) agent <- langgraphr::lg_connect()

  # Greet briefly.
  cat("Chat ready. Type 'quit' to exit.\n")

  repeat {
    # Read one line from the console.
    msg <- readline("You: ")
    # Empty input: prompt again.
    if (!nzchar(trimws(msg))) next
    # Quit words end the loop.
    if (tolower(trimws(msg)) %in% c("quit", "exit", "q")) {
      cat("Bye!\n")
      break
    }
    # Send the message; the same thread id keeps conversation memory.
    res <- tryCatch(agent$invoke(msg), error = function(e) {
      cat("Error:", conditionMessage(e), "\n")
      NULL
    })
    # Print the assistant's reply when the call succeeded.
    if (!is.null(res)) cat("Assistant:", res$content, "\n\n")
  }

  # Return the agent invisibly so the conversation can be continued later.
  invisible(agent)
}
