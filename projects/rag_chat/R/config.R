# config.R - provider + path configuration for the RAG chat app.
#
# The chat model follows the shared LANGGRAPHR_* convention (DeepSeek in
# this workspace, via an OpenAI-compatible endpoint). Embeddings need a
# separate backend because DeepSeek offers no embeddings endpoint: the
# default is a local key-free Ollama server, switchable to any
# OpenAI-compatible endpoint through the RAG_EMBED_* variables in .env.

rag_load_env <- function(env_path) {
  if (!is.null(env_path) && file.exists(env_path)) {
    try(dotenv::load_dot_env(env_path), silent = TRUE)
  }
}

rag_config <- function(project_dir) {
  list(
    project_dir = project_dir,
    data_dir = file.path(project_dir, "data", "chats"),
    model = Sys.getenv("LANGGRAPHR_MODEL", "deepseek-chat"),
    base_url = Sys.getenv("LANGGRAPHR_BASE_URL", "https://api.deepseek.com"),
    api_key = Sys.getenv("LANGGRAPHR_API_KEY", ""),
    embed_provider = tolower(Sys.getenv("RAG_EMBED_PROVIDER", "ollama")),
    embed_base_url = Sys.getenv("RAG_EMBED_BASE_URL", "http://localhost:11434"),
    embed_model = Sys.getenv("RAG_EMBED_MODEL", "nomic-embed-text"),
    embed_api_key = Sys.getenv("RAG_EMBED_API_KEY", ""),
    top_k = max(1L, as.integer(Sys.getenv("RAG_TOP_K", "5"))),
    history_turns = 10L,     # recent turns kept verbatim in the prompt
    compact_chars = 16000    # total history chars that trigger a summary
  )
}

# rag_embed_fn(cfg) - the embedding function ragnar will call for both
# indexing and retrieval. It must be the SAME backend for both, or the
# vectors live in different spaces and retrieval silently degrades.
rag_embed_fn <- function(cfg) {
  function(x) {
    switch(cfg$embed_provider,
      ollama = ragnar::embed_ollama(x, base_url = cfg$embed_base_url,
                                    model = cfg$embed_model),
      openai = ragnar::embed_openai(x, base_url = cfg$embed_base_url,
                                    api_key = cfg$embed_api_key,
                                    model = cfg$embed_model),
      lmstudio = ragnar::embed_lm_studio(x, base_url = cfg$embed_base_url,
                                         model = cfg$embed_model),
      cli::cli_abort("Unknown RAG_EMBED_PROVIDER '{cfg$embed_provider}' ",
                     "(use ollama, openai or lmstudio).")
    )
  }
}

# rag_embed_status(cfg) - "ok" when the embedding backend answers, else a
# short reason. The indexer calls this as a preflight before doing work.
rag_embed_status <- function(cfg) {
  tryCatch({
    v <- rag_embed_fn(cfg)("ping")
    if (is.matrix(v) && nrow(v) > 0L) "ok" else "embedding backend returned an unexpected shape"
  }, error = function(e) conditionMessage(e))
}

# rag_llm() - non-streaming chat completion through the langgraphr helper,
# which reads the same OpenAI-compatible endpoint from LANGGRAPHR_* envs.
rag_llm <- function(cfg, messages, temperature = NULL, max_tokens = NULL) {
  langgraphr::lg_call_model(
    messages, model = cfg$model, base_url = cfg$base_url,
    api_key = cfg$api_key, temperature = temperature, max_tokens = max_tokens)
}

# rag_chat_stream_client(cfg) - an ellmer Chat bound to the same endpoint,
# used only where token streaming matters (the answer node). ellmer 0.4
# deprecated the api_key argument in favor of `credentials`; fall back
# gracefully on older/newer signatures.
rag_chat_stream_client <- function(cfg) {
  if ("credentials_api_key" %in% getNamespaceExports("ellmer")) {
    tryCatch(
      ellmer::chat_openai(model = cfg$model, base_url = cfg$base_url,
                          credentials = ellmer::credentials_api_key(cfg$api_key)),
      error = function(e) suppressWarnings(
        ellmer::chat_openai(model = cfg$model, base_url = cfg$base_url,
                            api_key = cfg$api_key)))
  } else {
    suppressWarnings(ellmer::chat_openai(model = cfg$model,
                                         base_url = cfg$base_url,
                                         api_key = cfg$api_key))
  }
}
