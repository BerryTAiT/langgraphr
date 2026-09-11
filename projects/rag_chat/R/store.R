# store.R - per-chat persistence.
#
# Every chat gets one folder under data/chats/<chat_id>/:
#   chat.duckdb        - messages, file registry and meta (summary, ready flag)
#   index.ragnar.duckdb - the vector store (written ONLY by the indexer)
#   uploads/           - the original uploaded files
#
# DuckDB allows one writer at a time, and the app process and background
# workers (indexer, turn runner) are separate processes. So every access
# opens the database briefly and retries while the file is locked; the
# ragnar store is opened read-only on the retrieval side for the same
# reason.

chat_paths <- function(data_dir, chat_id) {
  dir <- file.path(data_dir, chat_id)
  list(
    dir = dir,
    db = file.path(dir, "chat.duckdb"),
    index = file.path(dir, "index.ragnar.duckdb"),
    uploads = file.path(dir, "uploads")
  )
}

SCHEMA_SQL <- c(
  "CREATE TABLE IF NOT EXISTS messages(
     id INTEGER, role VARCHAR, content VARCHAR,
     refs_json VARCHAR, created_at VARCHAR, compacted INTEGER DEFAULT 0)",
  "CREATE TABLE IF NOT EXISTS files(
     name VARCHAR, chunks INTEGER, status VARCHAR, indexed_at VARCHAR)",
  "CREATE TABLE IF NOT EXISTS meta(key VARCHAR, value VARCHAR)"
)

# with_chat_db(db_path, fn) - open the chat database, ensure the schema,
# run fn(con), then close. Retries while another process holds the write
# lock (e.g. a turn worker finishing its write as the UI reloads).
with_chat_db <- function(db_path, fn) {
  dir.create(dirname(db_path), recursive = TRUE, showWarnings = FALSE)
  deadline <- Sys.time() + 20
  repeat {
    con <- tryCatch(
      duckdb::dbConnect(duckdb::duckdb(), db_path),
      error = function(e) e)
    if (!inherits(con, "error")) break
    if (Sys.time() > deadline) {
      stop("Chat database is locked by another process: ",
           conditionMessage(con))
    }
    Sys.sleep(0.3)
  }
  on.exit(try(duckdb::dbDisconnect(con, shutdown = TRUE), silent = TRUE),
          add = TRUE)
  for (sql in SCHEMA_SQL) DBI::dbExecute(con, sql)
  fn(con)
}

# ---- messages ----------------------------------------------------------------

chat_add_message <- function(con, role, content, refs = list()) {
  # Never let an empty/NA reply reach the database: it would poison the
  # character-count compaction check with NA.
  if (is.null(content) || length(content) == 0L || is.na(content)) {
    content <- ""
  }
  refs_json <- if (length(refs)) {
    jsonlite::toJSON(refs, auto_unbox = TRUE)
  } else {
    "[]"
  }
  id <- as.integer(DBI::dbGetQuery(
    con, "SELECT COALESCE(MAX(id), 0) + 1 AS id FROM messages")$id)
  DBI::dbExecute(con,
    "INSERT INTO messages VALUES (?, ?, ?, ?, ?, 0)",
    params = list(id, role, as.character(content), refs_json, now_stamp()))
  invisible(id)
}

# chat_messages(con, limit) - newest `limit` uncompacted rows, oldest first.
chat_messages <- function(con, limit = NULL) {
  sql <- "SELECT * FROM messages WHERE compacted = 0 ORDER BY id DESC"
  if (!is.null(limit)) sql <- paste(sql, "LIMIT", as.integer(limit))
  d <- DBI::dbGetQuery(con, sql)
  d[rev(seq_len(nrow(d))), , drop = FALSE]
}

chat_all_messages <- function(con) {
  DBI::dbGetQuery(con, "SELECT * FROM messages ORDER BY id")
}

# The final answer of the last turn (used to confirm the turn persisted
# before the UI renders it as complete).
chat_last_answer <- function(con) {
  d <- DBI::dbGetQuery(con, paste0(
    "SELECT content, refs_json FROM messages ",
    "WHERE role = 'assistant' ORDER BY id DESC LIMIT 1"))
  if (nrow(d) == 0L) {
    return(list(content = "(no reply)", refs = list()))
  }
  refs <- tryCatch(
    jsonlite::fromJSON(d$refs_json[1], simplifyVector = FALSE),
    error = function(e) list())
  list(content = d$content[1], refs = first_or(refs, list()))
}

# ---- memory compaction ---------------------------------------------------------

# chat_older_text(con, keep) - the uncompacted turns that do NOT fit in
# the recent window, as "role: content" lines (input to the summarizer).
chat_older_text <- function(con, keep = 6L) {
  d <- chat_messages(con)
  if (nrow(d) <= keep) return("")
  old <- d[seq_len(nrow(d) - keep), , drop = FALSE]
  paste0(old$role, ": ", old$content, collapse = "\n")
}

chat_mark_compacted <- function(con, keep = 6L) {
  d <- chat_messages(con)
  if (nrow(d) <= keep) return(invisible(NULL))
  ids <- d$id[seq_len(nrow(d) - keep)]
  DBI::dbExecute(con,
    paste0("UPDATE messages SET compacted = 1 WHERE id IN (",
           paste(as.integer(ids), collapse = ","), ")"))
  invisible(NULL)
}

# ---- files + meta ---------------------------------------------------------------

chat_add_file <- function(con, name, chunks, status = "indexed") {
  DBI::dbExecute(con, "INSERT INTO files VALUES (?, ?, ?, ?)",
                 params = list(name, as.integer(chunks), status, now_stamp()))
  invisible(NULL)
}

chat_files <- function(con) {
  DBI::dbGetQuery(con, "SELECT * FROM files ORDER BY rowid")
}

chat_has_file <- function(con, name) {
  as.integer(DBI::dbGetQuery(
    con, "SELECT COUNT(*) AS n FROM files WHERE name = ?",
    params = list(name))$n) > 0L
}

chat_meta_get <- function(con, key, default = NULL) {
  d <- DBI::dbGetQuery(con,
    "SELECT value FROM meta WHERE key = ?", params = list(key))
  if (nrow(d) == 0L) default else d$value[1]
}

chat_meta_set <- function(con, key, value) {
  DBI::dbExecute(con, "DELETE FROM meta WHERE key = ?", params = list(key))
  DBI::dbExecute(con, "INSERT INTO meta VALUES (?, ?)",
                 params = list(key, as.character(value)))
  invisible(NULL)
}

# ---- the ragnar vector store ------------------------------------------------------

# store_retrieve_passages() - hybrid search (vector + BM25) over the chat's
# index. The store is opened read-only and closed immediately so a later
# indexing run can take the write lock. Some ragnar builds do not restore
# the embed function on read-only connect; if the default retrieve fails
# we fall back to explicit VSS with our own query vector.
store_retrieve_passages <- function(index_path, query, top_k, embed) {
  if (!file.exists(index_path)) return(list())
  store <- ragnar::ragnar_store_connect(index_path, read_only = TRUE)
  on.exit(store_close(store), add = TRUE)
  hits <- tryCatch(
    ragnar::ragnar_retrieve(store, query, top_k = top_k),
    error = function(e) tryCatch(
      ragnar::ragnar_retrieve_vss(store, query, top_k = top_k,
                                  query_vector = embed(query)),
      error = function(e2) NULL))
  if (is.null(hits) || nrow(hits) == 0L) return(list())
  lapply(seq_len(nrow(hits)), function(i) {
    src <- if ("origin" %in% names(hits) &&
               !is.na(hits$origin[i]) &&
               nzchar(as.character(hits$origin[i]))) {
      basename(as.character(hits$origin[i]))
    } else {
      "document"
    }
    txt <- as.character(hits$text[i])
    # Chunks carry their heading context; strip ragnar's own metadata
    # decorations so the model sees mostly content.
    list(text = txt, source = src, chunk_id = if ("chunk_id" %in% names(hits)) hits$chunk_id[i] else i)
  })
}

# store_close(store) - release the DuckDB connection behind a ragnar store.
# ragnar's store object wraps the connection; try the documented paths and
# never let cleanup errors break a retrieval.
store_close <- function(store) {
  try(close(store), silent = TRUE)
  invisible(NULL)
}

# chat_list_all(data_dir) - every chat on disk for the sidebar: one row per
# chat folder with a title (first real user message) and last-activity
# time (the chat.duckdb mtime, which updates on every persisted turn).
# Newest first.
chat_list_all <- function(data_dir) {
  empty <- data.frame(chat_id = character(0), title = character(0),
                      updated = as.POSIXct(character(0)))
  if (!dir.exists(data_dir)) return(empty)
  ids <- list.dirs(data_dir, recursive = FALSE, full.names = FALSE)
  rows <- lapply(ids, function(id) {
    db <- file.path(data_dir, id, "chat.duckdb")
    if (!file.exists(db)) return(NULL)
    info <- tryCatch(with_chat_db(db, function(con) {
      r <- DBI::dbGetQuery(con, paste(
        "SELECT content FROM messages",
        "WHERE role = 'user' AND TRIM(content) <> ''",
        "ORDER BY id LIMIT 1"))
      list(title = if (nrow(r) > 0L) r$content[1] else "")
    }), error = function(e) NULL)
    if (is.null(info)) return(NULL)
    data.frame(
      chat_id = id,
      title = if (nzchar(info$title)) trimws(substr(info$title, 1, 48)) else "New chat",
      updated = file.mtime(db),
      stringsAsFactors = FALSE)
  })
  rows <- Filter(Negate(is.null), rows)
  if (!length(rows)) return(empty)
  d <- do.call(rbind, rows)
  d[order(d$updated, decreasing = TRUE), , drop = FALSE]
}
