# utils.R - helpers shared by the graph nodes, the indexer and the UI.

first_or <- function(x, alt) {
  if (is.null(x) || length(x) == 0L) alt else x
}

now_stamp <- function() format(Sys.time(), "%H:%M:%S")

# time_ago(t) - compact relative time for the sidebar list ("now", "5m",
# "2h", "3d", then a date).
time_ago <- function(t) {
  if (is.null(t) || is.na(t)) return("")
  dt <- as.numeric(difftime(Sys.time(), t, units = "mins"))
  if (dt < 1) "now"
  else if (dt < 60) paste0(round(dt), "m")
  else if (dt < 60 * 24) paste0(round(dt / 60), "h")
  else if (dt < 60 * 24 * 7) paste0(round(dt / 1440), "d")
  else format(t, "%b %d")
}

# append_event(events_file, event) - write one event as a JSON line to the
# turn's event file. The Shiny app polls this file to show indexing
# progress and stream answer tokens in real time.
append_event <- function(events_file, event) {
  if (is.null(event$t)) event$t <- now_stamp()
  line <- jsonlite::toJSON(event, auto_unbox = TRUE, null = "null")
  cat(line, "\n", file = events_file,
      append = file.exists(events_file), sep = "")
}

esc_html <- function(x) htmltools::htmlEscape(as.character(x))

# parse_agent_response(text) - replies are light Markdown; convert to HTML
# for the custom feed: code fences, inline code, bold, newlines.
parse_agent_response <- function(text) {
  esc <- htmltools::htmlEscape(as.character(text))
  parts <- strsplit(esc, "```", fixed = TRUE)[[1]]
  out <- lapply(seq_along(parts), function(i) {
    seg <- parts[i]
    if (i %% 2 == 0L) {
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

user_bubble_html <- function(text) {
  paste0('<div class="msg-row user"><div class="bubble user">',
         esc_html(text), "</div></div>")
}

agent_bubble_html <- function(html, refs = NULL, error = FALSE) {
  cls <- if (isTRUE(error)) "bubble agent error" else "bubble agent"
  paste0('<div class="msg-row agent"><div class="avatar">', "\u2733", '</div>',
         '<div class="', cls, '">', html, refs_footnotes_html(refs),
         "</div></div>")
}

note_html <- function(text) {
  paste0('<div class="msg-note">', esc_html(text), "</div>")
}

# refs_footnotes_html(refs) - the source list under an answer: which
# passage number maps to which file and what it said (first 140 chars).
refs_footnotes_html <- function(refs) {
  refs <- first_or(refs, list())
  if (!length(refs)) return("")
  items <- vapply(refs, function(r) paste0(
    '<div class="ref"><span class="ref-n">[', esc_html(r$n), ']</span> ',
    '<span class="ref-src">', esc_html(first_or(r$source, "?")), '</span>',
    '<span class="ref-snip">', esc_html(first_or(r$snippet, "")), '</span></div>'),
    character(1))
  paste0('<details class="refs"><summary>Sources (', length(refs),
         ')</summary>', paste(items, collapse = ""), "</details>")
}

# sources_card_html(files) - the collapsible card at the top of the feed
# listing everything indexed for the current chat.
sources_card_html <- function(files) {
  if (!length(files)) return("")
  rows <- vapply(files, function(f) paste0(
    '<div class="src-row"><span class="src-name">',
    esc_html(first_or(f$name, "?")), '</span><span class="src-chunks">',
    esc_html(first_or(f$chunks, 0)), ' chunks</span></div>'), character(1))
  paste0('<details class="sources-card" open><summary>Indexed sources (',
         length(files), ")</summary>", paste(rows, collapse = ""), "</details>")
}

# chat_item_html(id, title, when, active) - one row of the sidebar's
# recent-conversation list; clicking posts the chat id to Shiny.
chat_item_html <- function(id, title, when, active = FALSE) {
  paste0(
    '<button class="chat-item', if (isTRUE(active)) " active" else "",
    '" onclick="Shiny.setInputValue(\'open_chat\', \'', esc_html(id),
    '\', {priority:\'event\'})">',
    '<span class="ci-title">', esc_html(title), '</span>',
    '<span class="ci-time">', esc_html(when), '</span></button>')
}


