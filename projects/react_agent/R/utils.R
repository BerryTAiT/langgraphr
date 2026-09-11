# utils.R - helpers shared by the agent loop and the Shiny front end.

# first_or(x, alt) - return x unless it is NULL/empty; a tiny helper that
# keeps API parsing code readable (and works on every R >= 4.1).
first_or <- function(x, alt) {
  if (is.null(x) || length(x) == 0L) alt else x
}

# now_stamp() - a short wall-clock timestamp for event entries.
now_stamp <- function() format(Sys.time(), "%H:%M:%S")

# append_event(events_file, event) - write one event as a JSON line to the
# turn's event file. The Shiny app polls this file to show the ReAct loop
# in real time while the background worker works.
append_event <- function(events_file, event) {
  if (is.null(event$t)) event$t <- now_stamp()
  line <- jsonlite::toJSON(event, auto_unbox = TRUE, null = "null")
  cat(line, "\n", file = events_file,
      append = file.exists(events_file), sep = "")
}

# format_tool_result(x) - flatten a JSON-safe tool result into compact text
# for the OBSERVE block (lists become "name: value" lines; long text is
# truncated so the card stays readable).
format_tool_result <- function(x, max_chars = 800) {
  text <- if (is.character(x) && length(x) == 1L) {
    x
  } else if (is.list(x)) {
    paste(vapply(names(x), function(nm) {
      sprintf("%s: %s", nm, paste(as.character(x[[nm]]), collapse = ", "))
    }, character(1)), collapse = "\n")
  } else {
    paste(utils::capture.output(print(x)), collapse = "\n")
  }
  if (nchar(text) > max_chars) {
    text <- paste0(substr(text, 1, max_chars), " ... (truncated)")
  }
  text
}

# format_args(args) - render tool arguments as "key: value" pairs for the
# ACT block of the tool card.
format_args <- function(args) {
  if (length(args) == 0L) return("(no arguments)")
  paste(vapply(names(args), function(nm) {
    sprintf("%s: %s", nm, paste(as.character(args[[nm]]), collapse = ", "))
  }, character(1)), collapse = ", ")
}

# parse_agent_response(text) - the agent replies in light Markdown; the
# custom message feed needs HTML, so convert: escape everything, then turn
# ```code fences``` into <pre> blocks, `inline code` and **bold** into
# elements, and newlines into <br>.
parse_agent_response <- function(text) {
  esc <- htmltools::htmlEscape(as.character(text))
  # Split on code fences; odd segments are code, even segments are prose.
  parts <- strsplit(esc, "```", fixed = TRUE)[[1]]
  out <- lapply(seq_along(parts), function(i) {
    seg <- parts[i]
    if (i %% 2 == 0L) {
      # Code fence: strip a leading language tag and wrap in a <pre>.
      seg <- sub("^[a-zA-Z0-9_+-]*\n", "", seg)
      paste0('<pre class="code-block">', seg, "</pre>")
    } else {
      seg <- gsub("\\*\\*(.+?)\\*\\*", "<strong>\\1</strong>", seg)
      seg <- gsub("`([^`]+)`", "<code>\\1</code>", seg)
      gsub("\n", "<br>", seg, fixed = TRUE)
    }
  })
  paste(unlist(out), collapse = "")
}

# ---- feed item builders -----------------------------------------------------
# Each returns one HTML string; the app renders them inside the feed.

# esc_html(x) - make plain text safe to embed in the feed's HTML.
esc_html <- function(x) htmltools::htmlEscape(as.character(x))

# user_bubble_html(text) - right-aligned periwinkle bubble, no label
# (GLM-style).
user_bubble_html <- function(text) {
  paste0('<div class="msg-row user"><div class="bubble user">',
         esc_html(text), "</div></div>")
}

# agent_bubble_html(html, error) - left-aligned reply with a gradient
# avatar, GLM-style; the content is already HTML (from
# parse_agent_response).
agent_bubble_html <- function(html, error = FALSE) {
  cls <- if (isTRUE(error)) "bubble agent error" else "bubble agent"
  paste0('<div class="msg-row agent"><div class="avatar">A</div>',
         '<div class="', cls, '">', html, "</div></div>")
}

# note_html(text) - small centered muted line (uploads, thread resets).
note_html <- function(text) {
  paste0('<div class="msg-note">', esc_html(text), "</div>")
}

# tool_card_html(events, open) - the ReAct visualization: a collapsible
# card built from the turn's event list. REASON explains why the model
# called a tool; ACT shows the call; OBSERVE shows the result; a table
# event renders as a minimal data preview. While a turn is running the
# app renders it with open = TRUE so the loop is visible live.
tool_card_html <- function(events, open = FALSE) {
  if (length(events) == 0L) return("")
  # Header reflects the current phase of the ReAct loop.
  has_error <- any(vapply(events, function(e)
    identical(e$type, "error"), logical(1)))
  n_steps <- sum(vapply(events, function(e)
    identical(e$type, "observe"), integer(1)))
  header <- if (has_error) {
    "⚙ Tool error"
  } else if (n_steps > 0L) {
    paste0("⚙ Calling tool — ", n_steps, " step(s)")
  } else {
    "⚙ Reasoning..."
  }
  # One block group per event, in order.
  blocks <- lapply(events, function(e) {
    switch(e$type,
      act = paste0(
        '<div class="block"><div class="block-label">Reason</div>',
        '<div class="block-text">', esc_html(first_or(e$reason, "")),
        '</div></div>',
        '<div class="block"><div class="block-label">Act</div>',
        '<div class="act-name">', esc_html(first_or(e$tool, "")),
        '</div><div class="kv">', esc_html(first_or(e$args, "")),
        "</div></div>"),
      observe = paste0(
        '<div class="block"><div class="block-label">Observe</div>',
        '<div class="observe-text">', esc_html(first_or(e$text, "")),
        "</div></div>"),
      table = {
        cols <- unlist(first_or(e$cols, list()))
        rows <- first_or(e$rows, list())
        head_cells <- paste0("<th>", esc_html(cols), "</th>",
                             collapse = "")
        body_rows <- paste(vapply(rows, function(r) {
          cells <- paste0("<td>", esc_html(unlist(r)), "</td>",
                          collapse = "")
          paste0("<tr>", cells, "</tr>")
        }, character(1)), collapse = "")
        paste0('<div class="block"><table class="observe-table">',
               "<tr>", head_cells, "</tr>", body_rows, "</table></div>")
      },
      error = paste0('<div class="block-error">',
                     esc_html(first_or(e$text, "")), "</div>"),
      "")
  })
  paste0('<div class="msg-row agent"><div class="avatar">A</div>',
         '<div class="bubble agent"><details class="tool-card"',
         if (isTRUE(open)) " open" else "",
         "><summary>", esc_html(header), "</summary>",
         '<div class="tool-body">',
         paste(unlist(blocks), collapse = ""), "</div></details></div></div>")
}

# greeting_html() - GLM-style empty state: gradient hello plus a 2x2 grid
# of clickable suggestion cards that pre-fill the input box.
greeting_html <- function() {
  cards <- list(
    list(icon = "\u2600", cls = "i1",
         text = "What's the weather in Tokyo?"),
    list(icon = "\u21c4", cls = "i2",
         text = "Convert 100 USD to EUR"),
    list(icon = "\U0001f30d", cls = "i3",
         text = "Tell me about Portugal"),
    list(icon = "\U0001f4ca", cls = "i4",
         text = "Upload a CSV and I'll summarize it"))
  card <- function(cd) {
    js <- paste0("var m=document.getElementById('msg');m.value=",
                 jsonlite::toJSON(cd$text), ";m.focus();")
    sprintf(paste0('<button class="card" onclick="%s">',
                   '<span class="card-icon %s">%s</span>',
                   '<span class="card-text">%s</span></button>'),
            esc_html(js), cd$cls, cd$icon, esc_html(cd$text))
  }
  paste0(
    '<div class="greeting"><h1>Hi, I&#39;m Ada.</h1>',
    paste0('<p>Ask me anything - I fetch live data and read your files ',
           'when needed.</p>'),
    '<div class="cards">',
    paste(vapply(cards, card, character(1)), collapse = ""),
    "</div></div>")
}
