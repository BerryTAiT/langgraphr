# utils.R - small console helpers for the chatbot.
#
# Pure presentation code: nothing here talks to the hidden server.

# print_message() renders one conversation turn with wrapped text so long
# answers stay readable in a console of any width.
print_message <- function(who, text, width = getOption("width")) {
  # "you" and "ada" get fixed labels; anything else is shown verbatim.
  prefix <- if (identical(who, "you")) "You: " else paste0(who, ": ")
  # Guard against a NULL/empty reply so strwrap() never chokes.
  text <- if (is.null(text) || !nzchar(text)) "(no reply)" else text
  # Wrap to the console width minus the label width.
  wrapped <- strwrap(text, width = max(40L, width - nchar(prefix)))
  # Print the label and the wrapped body as one block.
  cat(prefix, paste0(wrapped, collapse = "\n"), "\n\n", sep = "")
}

# print_banner() shows the startup screen and the available commands.
print_banner <- function() {
  cat("\n=============================================\n")
  cat("  r_chatbot - a console chatbot (langgraphr)\n")
  cat("=============================================\n")
  cat("Type a message and press Enter to chat.\n")
  cat("Commands:  clear = reset memory | quit/exit = leave\n\n")
}

# format_error() turns any caught error into a single friendly line.
format_error <- function(e) paste0("Error: ", conditionMessage(e))
