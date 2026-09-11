# modules_compat.R - self-contained helper extracted from the former
# langgraphr module/ experiment (deleted 2026-09-09). This project needs
# only tool-call parsing.

# Parse JSON tool_calls out of an LLM response string
lg_parse_tool_calls <- function(response) {
  # perl=TRUE required: TRE does not support [\s\S]
  json_match <- regmatches(
    response,
    regexpr('\\{[\\s\\S]*"tool_calls"[\\s\\S]*\\}', response, perl = TRUE)
  )

  if (length(json_match) == 0 || nchar(json_match) == 0) {
    return(list())
  }

  parsed <- tryCatch({
    jsonlite::fromJSON(json_match)
  }, error = function(e) NULL)

  if (is.null(parsed) || is.null(parsed$tool_calls)) {
    return(list())
  }

  if (is.data.frame(parsed$tool_calls)) {
    lapply(seq_len(nrow(parsed$tool_calls)), function(i) {
      as.list(parsed$tool_calls[i, ])
    })
  } else {
    parsed$tool_calls
  }
}
