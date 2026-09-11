# graph.R - the langgraphr conversation graph for one chat.
#
#   load_memory ──(no docs)────────────▶ refuse (canned answer)
#        └─(docs)─▶ guard_check ──(off-topic)──▶ refuse
#                     └─(related)─▶ rewrite_query? ─▶ retrieve
#                                                      │
#                                                      ▼
#                                                   generate ──▶ update_memory
#                                                      │(history too long)
#                                                      ▼
#                                                   summarize ──▶ __end__
#
# One user question = one graph invocation on a fresh thread. Durable
# memory lives in the chat's DuckDB (messages + running summary), not in
# graph state, so a page refresh or even an app restart loses nothing.

# The one canned answer for anything off-topic; used by the refuse node
# and repeated in the generate prompt as a second guard.
RAG_REFUSAL <- "I'm RagChat AI. I only answer questions related to your files."

RAG_SYSTEM_PROMPT <- paste0(
  "You are RagChat, a careful assistant that answers questions about the ",
  "user's documents.\n",
  "Rules:\n",
  "- Ground every claim in the numbered document excerpts [n] provided ",
  "in the message.\n",
  "- Cite the excerpts you use, like [1] or [2][3].\n",
  "- If the excerpts do not contain the answer, say so plainly - never ",
  "invent content.\n",
  "- If the latest question is not about the documents or the ",
  "conversation about them, reply with exactly: I'm RagChat AI. I only ",
  "answer questions related to your files.\n",
  "- Answer in the user's language.")

# rag_input_text(state) - the run's input text. invoke() posts the question
# as a string; the server surfaces it in the node state under its own key,
# so check the plausible names once, here.
rag_input_text <- function(state) {
  for (k in c("input", "question", "user_input", "message", "text")) {
    v <- state[[k]]
    if (is.character(v) && length(v) >= 1L && nzchar(v[1])) return(v[1])
  }
  ""
}

history_to_text <- function(hist) {
  if (is.null(hist) || length(hist) == 0L) return("")
  if (is.data.frame(hist)) {
    if (nrow(hist) == 0L) return("")
    return(paste0(hist$role, ": ", hist$content, collapse = "\n"))
  }
  # State can round-trip through the hidden server as JSON, which turns a
  # data frame into a list - handle that shape too.
  if (!is.null(hist$role) && !is.null(hist$content)) {
    return(paste0(hist$role, ": ", hist$content, collapse = "\n"))
  }
  roles <- vapply(hist, function(h) as.character(first_or(h$role, "")),
                  character(1))
  texts <- vapply(hist, function(h) as.character(first_or(h$content, "")),
                  character(1))
  paste0(roles, ": ", texts, collapse = "\n")
}

# build_rag_graph(cfg, chat_id, emit) - compile the graph. The node
# closures bind the chat's paths, the config and the event emitter, so the
# same compiled spec is specific to this turn's worker process.
build_rag_graph <- function(cfg, chat_id, emit) {
  p <- chat_paths(cfg$data_dir, chat_id)
  embed <- rag_embed_fn(cfg)

  load_memory <- function(state) {
    q <- rag_input_text(state)
    if (!nzchar(q)) {
      stop("No question text reached the graph. State keys seen: ",
           paste(names(state), collapse = ", "))
    }
    d <- with_chat_db(p$db, function(con) list(
      hist = chat_messages(con, limit = cfg$history_turns),
      summary = chat_meta_get(con, "summary", ""),
      digest = chat_meta_get(con, "digest", "")))
    # History becomes TEXT before it enters graph state: string channels
    # survive the server round-trip between nodes, data frames may not.
    has_docs <- file.exists(p$index) || nzchar(d$digest)
    goto <- if (!has_docs) {
      # Nothing on file: the default answer applies, no model call needed.
      "refuse"
    } else {
      "guard_check"
    }
    list(updates = list(question = q,
                        history_text = history_to_text(d$hist),
                        summary = d$summary,
                        digest = d$digest),
         goto = goto)
  }

  # guard_check - the guardrail. Decides whether the question can be
  # answered from the user's documents or the conversation about them.
  # Deliberately generous with indirect questions - pronouns, follow-ups
  # and vague phrasing count as related, because relevance is judged
  # against the conversation and the document digest, not keywords.
  guard_check <- function(state) {
    prompt <- paste0(
      "Decide whether the user's latest question can be answered from ",
      "their indexed documents, or is a natural follow-up to the earlier ",
      "conversation about those documents.\n",
      "Be generous: a question may look arbitrary, vague or indirect ",
      "(pronouns like 'it' or 'the second one', 'explain that part') yet ",
      "still be related - judge it against BOTH the documents and the ",
      "recent conversation. Small talk, general world knowledge, coding ",
      "help, math or news questions with no plausible tie to the ",
      "documents are UNRELATED.\n\n",
      "The user's documents:\n",
      if (nzchar(first_or(state$digest, ""))) state$digest else
        "(no description available)",
      "\n\nRecent conversation:\n",
      first_or(state$history_text, "(none)"),
      "\n\nLatest question: ", state$question,
      "\n\nReply with exactly one word: RELATED or UNRELATED.")
    verdict <- tryCatch(
      rag_llm(cfg, list(list(role = "user", content = prompt)),
              temperature = 0, max_tokens = 30),
      error = function(e) "RELATED")
    # Fail open: if the check itself fails, let retrieval try.
    unrelated <- grepl("UNRELATED", toupper(first_or(verdict, "RELATED")),
                       fixed = TRUE)
    emit(list(type = "stage",
              stage = if (unrelated) "off-topic" else "on-topic"))
    list(updates = list(),
         goto = if (unrelated) {
           "refuse"
         } else if (nzchar(first_or(state$history_text, ""))) {
           "rewrite_query"
         } else {
           "retrieve"
         })
  }

  # refuse - the canned default answer; no model involved.
  refuse <- function(state) {
    list(updates = list(answer = RAG_REFUSAL, refs = list()))
  }

  rewrite_query <- function(state) {
    prompt <- paste0(
      "Rewrite the user's latest question as one standalone search query ",
      "against their document collection. Resolve pronouns and references ",
      "using the recent conversation. Reply with ONLY the query text.\n\n",
      "Recent conversation:\n", first_or(state$history_text, ""),
      "\n\nLatest question: ", state$question)
    query <- tryCatch(
      rag_llm(cfg, list(list(role = "user", content = prompt)),
              temperature = 0),
      error = function(e) state$question)
    query <- trimws(substr(first_or(query, state$question), 1, 400))
    if (!nzchar(query)) query <- state$question
    emit(list(type = "stage", stage = "rewrote-query", text = query))
    list(updates = list(query = query))
  }

  retrieve <- function(state) {
    q <- first_or(state$query, state$question)
    emit(list(type = "stage", stage = "retrieving", text = q))
    passages <- store_retrieve_passages(p$index, q, cfg$top_k, embed)
    if (!length(passages)) {
      emit(list(type = "stage", stage = "no-matches"))
      refs <- list()
      context <- "(no matching passages were found in the documents)"
    } else {
      refs <- lapply(seq_along(passages), function(i) list(
        n = i,
        source = passages[[i]]$source,
        snippet = substr(passages[[i]]$text, 1, 140)))
      context <- paste(vapply(seq_along(passages), function(i) paste0(
        "[", i, "] (", passages[[i]]$source, ")\n",
        passages[[i]]$text, "\n"), character(1)), collapse = "\n")
    }
    list(updates = list(chunks = passages, refs = refs, context = context))
  }

  generate <- function(state) {
    # Single-shot prompt: memory and excerpts are folded into one user
    # message so streaming needs no client-side conversation seeding.
    sum_txt <- first_or(state$summary, "")
    hist_txt <- first_or(state$history_text, "")
    user_block <- paste0(
      "You answer questions about the user's documents. Ground every ",
      "claim in the numbered excerpts [n] and cite them. If the excerpts ",
      "do not contain the answer, say so plainly. If the latest question ",
      "is not about the documents or this conversation, reply with ",
      "exactly: ", RAG_REFUSAL, "\n\n",
      if (nzchar(sum_txt)) paste0(
        "Summary of earlier conversation:\n", sum_txt, "\n\n") else "",
      if (nzchar(hist_txt)) paste0(
        "Recent conversation:\n", hist_txt, "\n\n") else "",
      "Document excerpts:\n", first_or(state$context, "(none)"),
      "\n\nQuestion: ", state$question)

    answer <- ""
    ch <- tryCatch(rag_chat_stream_client(cfg), error = function(e) NULL)
    streamed <- FALSE
    if (!is.null(ch)) {
      streamed <- tryCatch({
        it <- ch$stream(user_block)
        coro::loop(for (tk in it) {
          answer <- paste0(answer, tk)
          emit(list(type = "token", text = tk))
        })
        nzchar(answer)
      }, error = function(e) FALSE)
    }
    if (!streamed) {
      answer <- rag_llm(cfg, list(
        list(role = "system", content = RAG_SYSTEM_PROMPT),
        list(role = "user", content = user_block)))
      emit(list(type = "token", text = answer))
    }
    # A model can return an empty or NA reply; never let NA into state.
    if (is.null(answer) || length(answer) == 0L || is.na(answer)) answer <- ""
    list(updates = list(answer = as.character(answer)[1]))
  }

  update_memory <- function(state) {
    with_chat_db(p$db, function(con) {
      chat_add_message(con, "user", state$question)
      chat_add_message(con, "assistant", first_or(state$answer, ""),
                       first_or(state$refs, list()))
    })
    total <- with_chat_db(p$db, function(con) {
      d <- chat_all_messages(con)
      sum(nchar(ifelse(is.na(d$content), "", d$content)))
    })
    list(updates = list(),
         goto = if (total > cfg$compact_chars) "summarize" else "__end__")
  }

  summarize <- function(state) {
    keep <- 6L
    d <- with_chat_db(p$db, function(con) list(
      older = chat_older_text(con, keep),
      summary = chat_meta_get(con, "summary", "")))
    if (nzchar(d$older)) {
      prompt <- paste0(
        "Compress the older conversation below into a running summary. ",
        "Merge with the existing summary if there is one. Keep names, ",
        "numbers, decisions and what the documents contain. Be concise.\n\n",
        "Existing summary:\n", first_or(d$summary, "(none)"),
        "\n\nOlder conversation:\n", d$older)
      s <- tryCatch(
        rag_llm(cfg, list(list(role = "user", content = prompt)),
                temperature = 0.2),
        error = function(e) d$summary)
      with_chat_db(p$db, function(con) {
        chat_meta_set(con, "summary", s)
        chat_mark_compacted(con, keep = keep)
      })
    }
    list(updates = list(), goto = "__end__")
  }

  b <- langgraphr::lg_graph(
    # Unique per turn-worker so two chats never overwrite each other's
    # node registrations on the shared hidden server.
    paste0("rag_", chat_id, "_", as.integer(Sys.time())),
    state = list(
      question = list(type = "str", reducer = "overwrite"),
      query    = list(type = "str", reducer = "overwrite"),
      history_text = list(type = "str", reducer = "overwrite"),
      summary  = list(type = "str", reducer = "overwrite"),
      digest   = list(type = "str", reducer = "overwrite"),
      context  = list(type = "str", reducer = "overwrite"),
      chunks   = list(type = "list", reducer = "overwrite"),
      refs     = list(type = "list", reducer = "overwrite"),
      answer   = list(type = "str", reducer = "overwrite")),
    entry = "load_memory")
  b <- langgraphr::lg_add_node(b, "load_memory", load_memory,
                               "load chat memory, route to rewrite or retrieve")
  b <- langgraphr::lg_add_node(b, "rewrite_query", rewrite_query,
                               "make the question standalone")
  b <- langgraphr::lg_add_node(b, "retrieve", retrieve,
                               "hybrid vector + BM25 search")
  b <- langgraphr::lg_add_node(b, "generate", generate,
                               "stream a grounded, cited answer")
  b <- langgraphr::lg_add_node(b, "update_memory", update_memory,
                               "persist the turn")
  b <- langgraphr::lg_add_node(b, "guard_check", guard_check,
                               "relevance guardrail: documents only")
  b <- langgraphr::lg_add_node(b, "refuse", refuse,
                               "canned default answer")
  b <- langgraphr::lg_add_node(b, "summarize", summarize,
                               "compact old turns into a summary")
  b <- langgraphr::lg_add_edge(b, "rewrite_query", "retrieve")
  b <- langgraphr::lg_add_edge(b, "retrieve", "generate")
  b <- langgraphr::lg_add_edge(b, "generate", "update_memory")
  b <- langgraphr::lg_add_edge(b, "refuse", "update_memory")
  langgraphr::lg_compile(b)
}

# run_turn_worker() - one Q&A turn, self-contained for a background
# process. Everything durable happens inside the graph's update_memory /
# summarize nodes, so by the time this returns the turn is on disk.
run_turn_worker <- function(chat_id, question, env_path, project_dir,
                            events_file) {
  for (f in c("utils.R", "config.R", "store.R", "indexer.R", "graph.R")) {
    source(file.path(project_dir, "R", f), local = TRUE)
  }
  suppressPackageStartupMessages({
    library(langgraphr)
    library(ragnar)
    library(duckdb)
    library(jsonlite)
    library(ellmer)
    library(coro)
  })
  rag_load_env(env_path)
  cfg <- rag_config(project_dir)
  emit <- function(e) append_event(events_file, e)
  graph <- build_rag_graph(cfg, chat_id, emit)
  thread <- paste0(chat_id, "_", as.integer(Sys.time()), "_",
                   sample.int(1e6, 1))
  graph$invoke(question, thread_id = thread, max_rounds = 20L)
  # Confirm from the chat DB (not from graph state) what was persisted.
  p <- chat_paths(cfg$data_dir, chat_id)
  final <- with_chat_db(p$db, function(con) chat_last_answer(con))
  emit(list(type = "done", text = final$content, refs = final$refs))
  final
}
