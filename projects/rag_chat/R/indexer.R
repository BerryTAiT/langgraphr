# indexer.R - background document ingestion for one chat.
#
# Runs in a callr worker: reads each uploaded file to markdown, chunks it,
# embeds it into the chat's ragnar store, and streams progress as JSONL
# stage events the UI polls. Text tables (CSV/XLSX) are converted to
# markdown tables first; PDF/HTML/DOCX/MD/TXT go through ragnar's
# read_as_markdown().

# to_md_table(df) - a data frame as a markdown table (capped rows so a
# huge export does not produce one gigantic chunk).
to_md_table <- function(df, max_rows = 4000) {
  df <- head(df, max_rows)
  df[] <- lapply(df, function(x) trimws(as.character(x)))
  df[is.na(df)] <- ""
  head_line <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep_line <- paste0("|", paste(rep(" --- ", ncol(df)), collapse = "|"), "|")
  body <- vapply(seq_len(nrow(df)), function(i) {
    paste0("| ", paste(unlist(df[i, ]), collapse = " | "), " |")
  }, character(1))
  paste(c(head_line, sep_line, body), collapse = "\n")
}

csv_to_markdown <- function(path, max_rows = 4000) {
  to_md_table(utils::read.csv(path, check.names = FALSE, nrows = max_rows))
}

xlsx_to_markdown <- function(path, max_rows = 4000) {
  if (!requireNamespace("readxl", quietly = TRUE)) {
    stop("Install the 'readxl' package to index Excel files.")
  }
  to_md_table(readxl::read_excel(path, n_max = max_rows))
}

# read_any_markdown(path) - one reader for every supported upload, with
# manual fallbacks when ragnar's reader cannot handle a file.
read_any_markdown <- function(path) {
  ext <- tolower(tools::file_ext(path))
  md <- tryCatch(ragnar::read_as_markdown(path), error = function(e) NULL)
  if (!is.null(md)) return(md)
  switch(ext,
    csv = csv_to_markdown(path),
    xlsx = , xls = xlsx_to_markdown(path),
    txt = , md = , markdown = , log = , r = ,
      paste(readLines(path, warn = FALSE), collapse = "\n"),
    pdf = paste(unlist(pdftools::pdf_text(path)), collapse = "\n\n"),
    stop("Unsupported file type: .", ext))
}

# index_worker() - one indexing job, self-contained for a background
# process (sources its own dependencies, streams events, writes both the
# vector store and the chat DB). Files already indexed in this chat are
# skipped so a re-upload after an interrupted run never duplicates chunks.
index_worker <- function(chat_id, files, env_path, project_dir, events_file) {
  for (f in c("utils.R", "config.R", "store.R", "indexer.R")) {
    source(file.path(project_dir, "R", f), local = TRUE)
  }
  suppressPackageStartupMessages({
    library(ragnar)
    library(duckdb)
    library(jsonlite)
  })
  rag_load_env(env_path)
  cfg <- rag_config(project_dir)
  emit <- function(e) append_event(events_file, e)
  p <- chat_paths(cfg$data_dir, chat_id)
  dir.create(p$uploads, recursive = TRUE, showWarnings = FALSE)

  # Preflight: without a working embedding backend nothing else matters.
  emit(list(type = "stage", stage = "embed-check"))
  st <- rag_embed_status(cfg)
  if (!identical(st, "ok")) {
    emit(list(type = "error", text = paste0(
      "Embedding backend is not available (", st, "). ",
      "Fix: install Ollama from https://ollama.com then run ",
      "'ollama pull ", cfg$embed_model, "', or point RAG_EMBED_* in .env ",
      "at an OpenAI-compatible embeddings endpoint.")))
    return(invisible(NULL))
  }
  embed <- rag_embed_fn(cfg)

  # Fresh store on first upload; existing store gains new files only.
  store <- if (file.exists(p$index)) {
    ragnar::ragnar_store_connect(p$index, read_only = FALSE)
  } else {
    ragnar::ragnar_store_create(p$index, embed = embed)
  }
  on.exit(store_close(store), add = TRUE)

  n <- nrow(files)
  digest_parts <- list()  # per-file summaries for the guardrail check
  for (i in seq_len(n)) {
    nm <- files$name[i]
    already <- with_chat_db(p$db, function(con) chat_has_file(con, nm))
    if (already) {
      emit(list(type = "file-done", file = nm, chunks = 0L,
                skipped = TRUE, i = i, n = n))
      next
    }
    emit(list(type = "stage", stage = "reading", file = nm, i = i, n = n))
    # Prepend the file name as a heading: chunks carry heading context, so
    # every passage keeps the identity of the file it came from even when
    # the reader could not attach origin metadata (csv/txt fallbacks).
    md <- paste0("# ", nm, "\n\n", read_any_markdown(files$path[i]))
    # A compact description of this file feeds the guardrail's relevance
    # check on every later question.
    digest_parts[[length(digest_parts) + 1L]] <- list(
      name = nm, about = substr(gsub("\\s+", " ", md), 1, 400))
    emit(list(type = "stage", stage = "chunking", file = nm, i = i, n = n))
    chunks <- ragnar::markdown_chunk(md, target_size = 1400,
                                     target_overlap = 0.15)
    n_chunks <- tryCatch(length(chunks), error = function(e) 1L)
    emit(list(type = "stage", stage = "embedding", file = nm,
              chunks = n_chunks, i = i, n = n))
    ragnar::ragnar_store_insert(store, chunks)
    with_chat_db(p$db, function(con) chat_add_file(con, nm, n_chunks))
    emit(list(type = "file-done", file = nm, chunks = n_chunks,
              i = i, n = n))
  }

  digest_txt <- if (length(digest_parts)) {
    paste(vapply(digest_parts, function(d) {
      paste0("- ", d$name, ": ", d$about)
    }, character(1)), collapse = "\n")
  } else {
    ""
  }
  with_chat_db(p$db, function(con) chat_meta_set(con, "digest", digest_txt))
  emit(list(type = "stage", stage = "building-index"))
  ragnar::ragnar_store_build_index(store)
  with_chat_db(p$db, function(con) chat_meta_set(con, "ready", "1"))
  emit(list(type = "indexed", n_files = n))
  invisible(NULL)
}
