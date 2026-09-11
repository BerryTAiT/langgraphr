# RagChat - conversational RAG over your own documents

Upload a file, it is indexed immediately, then ask as many questions as
you want. Answers are grounded in your documents with citations, and the
conversation **remembers itself across page refreshes and even app
restarts** - all memory lives on disk, per chat.

Built on:

- **langgraphr** - the conversation is a real graph:
  `load_memory -> (rewrite_query) -> retrieve -> generate -> update_memory -> (summarize)`
  with conditional `goto` routing and a compaction loop.
- **ragnar** - document reading (`read_as_markdown`), chunking
  (`markdown_chunk`), embeddings and hybrid retrieval (vector + BM25)
  backed by a DuckDB store.
- **DuckDB** - per-chat chat history + file registry (`chat.duckdb`).
- **DeepSeek** (or any OpenAI-compatible chat endpoint) via the shared
  `LANGGRAPHR_*` convention; embeddings via a local **Ollama** server
  (key-free) by default.

## Quick start

```r
# 1. One-time: a local, key-free embedding backend.
#    Install Ollama from https://ollama.com, then in a terminal:
#    ollama pull nomic-embed-text

# 2. One-time: R packages
install.packages(c("shiny", "bslib", "shinyjs", "jsonlite", "promises",
                   "callr", "later", "duckdb", "ragnar", "dotenv"))

# 3. Run
shiny::runApp("projects/rag_chat/app.R")
```

Then: paperclip -> upload a PDF / DOCX / HTML / MD / TXT / CSV / XLSX ->
wait for "Indexed" -> ask anything.

## .env settings

| Variable | Meaning | Default |
|---|---|---|
| `LANGGRAPHR_MODEL` | chat model | `deepseek-v4-flash` |
| `LANGGRAPHR_BASE_URL` | OpenAI-compatible chat endpoint | `https://api.deepseek.com` |
| `LANGGRAPHR_API_KEY` | chat API key | (workspace key) |
| `RAG_EMBED_PROVIDER` | `ollama` \| `openai` \| `lmstudio` | `ollama` |
| `RAG_EMBED_BASE_URL` | embeddings endpoint | `http://localhost:11434` |
| `RAG_EMBED_MODEL` | embeddings model | `nomic-embed-text` |
| `RAG_TOP_K` | passages retrieved per question | `5` |

## How persistence works

```
data/chats/<chat_id>/
  chat.duckdb          messages, running summary, file registry, ready flag
  index.ragnar.duckdb  the vector store (written only by the indexer)
  uploads/             your original files
```

- The chat identity is a token in browser `localStorage`; on refresh the
  app reloads history + indexed files for that token. "New chat" mints a
  new token (the old chat's data stays on disk).
- Long conversations stay within the model's context: the graph keeps the
  last 10 turns verbatim, and once the total history grows past
  `compact_chars` a `summarize` node compresses older turns into a
  running summary. Nothing is deleted - only the prompt is bounded.
- Indexing and answering run in background `callr` processes and stream
  progress/tokens as JSONL events the UI polls every 600 ms (the same
  pattern as the react_agent project).

## Troubleshooting

- **"Embedding backend is not available"** - Ollama is not running or the
  model is not pulled. Start Ollama and run
  `ollama pull nomic-embed-text`, or point `RAG_EMBED_*` at an
  OpenAI-compatible embeddings endpoint (DeepSeek itself has none).
- **"Chat database is locked"** - a background job from a previous
  session is still holding the file; wait a few seconds and retry.
- **Refresh during indexing** - the background job dies with the session;
  just re-upload the same files (already-indexed files are skipped, never
  duplicated).
- **Refresh mid-answer** - the turn is persisted only when it completes;
  re-ask the question.

## Next step: corrective RAG

The graph is the upgrade path. Add a `grade_chunks` node after
`retrieve` that asks the model whether each passage actually answers the
question, and `goto = "rewrite_query"` back around when nothing passes -
a true cycle. The UI needs no changes.
