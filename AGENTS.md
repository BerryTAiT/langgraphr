# langgraphr Project Memory

## projects/react_agent (built 2026-09-05, verified complete)
- ReAct agent with a custom Shiny chat UI (no shinychat; hand-rolled
  feed in `app.R` + `www/styles.css`, GLM/Z.ai-style LIGHT theme:
  bg #f4f6f9, primary #3859ff, Inter/JetBrains Mono).
- `R/agent.R` — react_tool_defs(), make_react_tools(), react_worker()
  (drives the interrupt loop MANUALLY via internal
  `langgraphr:::.lg_perform_retrying` / `.lg_coerce_args` / `.lg_call_tool`
  / `.lg_prep_result` so every REASON/ACT/OBSERVE step streams as JSONL
  events; the UI polls the event file every 600 ms).
- `R/tools.R` — 7 tools: get_weather, get_exchange_rate, get_country_info
  (all free key-less APIs), read_data_file (CSV/xlsx), read_text_file
  (txt/PDF via pdftools), list_uploaded_files, summarize_dataframe.
- Agent turn runs in a background process (callr + promises); uploads go
  to a per-session temp dir with an upload_manifest.json.
- Verified 2026-09-05: all files parse, packages present, JSONL event
  round-trip OK, get_weather live call OK. Run with
  `shiny::runApp("projects/react_agent/app.R")`. Needs `.env` with
  LANGGRAPHR_* settings (already present).

## projects/r_chatbot (built 2026-09-05)
- Console (main.R) + Shiny (app.R, shinychat) chatbot sharing the same
  brain in `R/graph.R`, `R/tools.R`; SQLite persistent memory.

## projects/rag_chat (built 2026-09-06, verified) — "Sage" conversational RAG
- Upload PDF/DOCX/HTML/MD/TXT/CSV/XLSX -> background indexer (callr,
  JSONL stage events) -> ask questions with citations; memory persists
  across refresh AND app restart (per-chat files under `data/chats/<id>/`:
  `chat.duckdb` messages/meta/files, `index.ragnar.duckdb` vector store,
  `uploads/`). Chat identity = localStorage token (`sage_chat_id`).
- UI restyled 2026-09-06 to a Claude (Anthropic) look: ivory #faf9f5 bg,
  terracotta #d97757 accent, Lora serif brand, starburst glyph avatar,
  avatar-free assistant rows, warm-sand user bubbles, two-row composer.
  Empty-state greeting + suggestion cards removed (user request): fresh
  chats show a blank feed. Not a sibling of react_agent's GLM theme.
- Sidebar (2026-09-06): collapsible left panel with recent conversations.
  `chat_list_all()` in store.R reads every `data/chats/<id>/chat.duckdb`
  (title = first user message, order = chat.duckdb mtime); clicking a row
  posts `open_chat` -> `setChatId` custom message -> normal reload. Model
  chip removed from topbar; brand + New chat live in the sidebar.
- Guardrails (2026-09-06): renamed Sage -> RagChat. Every turn is gated
  by a `guard_check` node: an LLM classifies RELATED/UNRELATED against a
  per-chat `digest` (per-file summaries written by the indexer into chat
  meta) plus the conversation history; deliberately generous with
  indirect questions and follow-ups. UNRELATED -> `refuse` node returns
  the canned answer ("I'm RagChat AI. I only answer questions related to
  your files."); doc-less chats go straight to refuse with no model call.
  The generate prompt repeats the persona rule as a second guard.
- Graph (`R/graph.R`): load_memory -> (rewrite_query if history) ->
  retrieve -> generate (streams tokens via ellmer `$stream` + coro) ->
  update_memory -> (summarize if history > compact_chars). Nodes route via
  `goto`; one turn = one `invoke()` on a fresh thread.
- Chat model: DeepSeek via shared LANGGRAPHR_* .env convention.
  Embeddings: RAG_EMBED_* (default Ollama `nomic-embed-text`, key-free) —
  DeepSeek has NO embeddings endpoint.
- Verified 2026-09-06: all files parse; store layer, CSV->markdown,
  markdown_chunk OK; ragnar create/insert/build_index/retrieve OK (fake
  embedder; lock releases); DeepSeek live (PONG + real answers); full
  E2E turn 3.3 s with streamed tokens persisted to DuckDB. Real-document
  indexing awaits Ollama install (`ollama pull nomic-embed-text`); the UI
  shows setup instructions if the embedding backend is down.
- Hard-won gotchas (apply to any new langgraphr graph project):
  - `LgGraph$invoke(input)` sends the question as TEXT; node state
    receives it under the key `input`.
  - Node state round-trips through the hidden server as JSON: data
    frames get mangled (nrow -> NULL -> "missing value where TRUE/FALSE
    needed"). Pass derived TEXT via str channels, never raw data frames.
  - ragnar stores have no close method; `close()` errors are ignorable,
    RO connect + retrieve works, locks release. Retrieve hits: text,
    origin (NA for bare-string markdown), chunk_id.
  - ellmer 0.4.2: `chat_openai(api_key=)` deprecated (use `credentials`
    arg; rag_chat_stream_client handles both). `$stream()` works with
    DeepSeek (`base_url = "https://api.deepseek.com"`).
  - `lg_call_model` with tiny `max_tokens` returns an empty string.

## projects/autopatch (built 2026-09-10, verified) — code-modernization engine
- Console app (`main.R`) that audits `sample_repo/` (4 defective R files),
  patches each file via a nested worker subgraph (refactor ⇄ test cycle with
  stderr feedback, LLM-first + deterministic rule fallback), aggregates
  results through an append-reducer `fixes` channel, parks at a human gate
  (y/N, `--yes`, or `--park <file>`), then writes a PR bundle to `patches/`.
- Orchestrator: scanner -> dispatch (SELF-CYCLE = sequential map-reduce over
  the queue) -> gate -> pr. Worker: refactor -> test cycle. Both in
  `R/graph.R`; two separately compiled graphs, worker invoked nested inside
  the dispatch node. SQLite checkpoints (`autopatch.db`) via `lg_use_sqlite()`.
- Verified 2026-09-10: happy path 4/4 patched; `--stress` forces attempt-2
  retry cycle; rejection path writes no PR; crash test (kill R + server at
  gate) -> re-invoke on same thread shows old+new records (append channel
  survived full crash); `--resume` probe 404s (see gap below).
- PACKAGE BUG FIXED (2026-09-10): runtime.py used to add static edges for
  every default edge; with LangGraph 1.2.11 a node returning Command(goto=X)
  while its static edge points at Y fans out to BOTH -> two simultaneous
  node interrupts -> next resume 500s ("must specify the interrupt id").
  Fix: no static per-node edges; routing is fully Command-driven. Fixed in
  `00-project/annotated/py/runtime.md`, regenerated, reinstalled.
- Remaining package gaps (documented in autopatch/README.md): no parallel
  Send; `_thread_kind` in app.py is in-memory so `/resume` after a server
  restart 404s despite durable checkpoints; hard-killing R orphans the
  sidecar (processx supervision can't run on TerminateProcess).
- Authoring sharp edge: `lg_add_node`/`lg_add_edge` return a NEW builder —
  always reassign `b <- ...`. Node functions register via a shared env even
  without reassignment, so a forgotten reassign silently yields missing
  edges/defaults (run just ends early). Worker thread ids must be unique
  per run or worker state (attempts, content) leaks across runs.
- Chat mode (2026-09-10, reworked same day per user feedback): chat is now
  the DEFAULT; the patch pipeline requires `--run` (or a pipeline flag like
  --yes/--no-llm/--stress/--park). Flow: wait for the user's code first,
  then review - the y/N gate belongs only to the --run pipeline (after
  diffs). `R/chat.R`: AUTOPATCH_PERSONA (wait-then-review, never ask
  yes/no in chat) + 7 tools (ap_list_runs, ap_run_report, ap_list_repo_
  files, ap_read_file, ap_scan_file, ap_scan_repo, ap_read_diff) + a
  `code` command that collects multi-line pasted R until a `###` line and
  sends it for review. Tools return plain text. Verified live: run-history
  Q + repo defect scan + line-by-line code review all work.
- CRITICAL Windows/Rscript stdin lesson (2026-09-10, probe-verified):
  under Rscript, R's `stdin()` connection IS the script's own execution
  stream - `readLines(stdin())` consumes the script's remaining lines as
  data, and `readline()` returns "" forever (infinite loop: 1.5M empty
  prompts in one runaway test). Piped console input is unreachable. Any
  interactive REPL must (a) run only under `interactive()` via source()
  in RStudio/R console, (b) detect !interactive() and exit with guidance,
  and (c) never `quit()` at top level after the REPL when sourced
  interactively - it would kill the user's R session; branch with if/else
  so the script also can't fall through to pipeline code.
- Web UI (2026-09-10): `projects/autopatch/app.R` is a shinychat front end
  over the SAME chat.R brain. Run with
  `shiny::runApp("projects/autopatch/app.R")`. Pattern = r_chatbot's
  shinychat wiring + react_agent's callr background turn. USER PREFERENCE
  (2026-09-10): the UI must stay STOCK shinychat - plain `page_fillable` +
  `chat_ui()`, default light theme, NO custom sidebar/brand/chips, no
  `www/styles.css` (I over-themed it with a dark GitHub-style look and the
  user reverted it; keep it default from now on). A single "New
  conversation" button in a plain header is the only extra chrome.
  CRITICAL callr lesson (probe-verified): callr workers get a fresh global
  env and do NOT serialize cross-file function references ("could not find
  function" when a tool calls scan_defects/lcs_diff from another file) - the
  worker turn (ap_chat_turn in chat.R) must re-source defects.R +
  test_runner.R + chat.R itself before wiring the agent. Also: quick-action
  chips call update_chat_user_input(...submit=TRUE); verify the background
  worker with test_app_worker.R (two turns on one thread prove memory
  survives across separate workers).

## Folder convention (user instruction, 2026-09-05)
- **All new project work goes into the `projects/` folder** at the repo root
  (`creatingWrapper For LangGraph/projects/`). It is currently empty and
  reserved for new projects. Follow this for any new app, script, example,
  or experiment the user asks to create.

## Repo layout (after 2026-09-05 restructure)
- `LanggraphR/` — the R package (`langgraphr`), containing:
  - `DESCRIPTION`, `NAMESPACE`, `R/`, `inst/` (incl. `inst/server/` Python
    FastAPI sidecar), `tests/`, `man/`
  - `00-project/` — design specs + `annotated/` Markdown source of truth
  - `scripts/` — PowerShell build/setup tools, `tools/extract_code.py`
    (annotated MD -> real files), `tools/sync_annotated.py` (reverse sync)
  - `README.md`, `HISTORY.md`
- `.github/workflows/R-CMD-check.yaml` — CI (paths reference `LanggraphR/`)
- Never hand-edit generated files; edit the annotated MD and re-run
  `extract_code.py` (or run `sync_annotated.py` after hand-refining).

## Environment notes
- Windows/NTFS is case-insensitive: `langgraphr` and `LanggraphR` are the
  SAME folder name; git pathspecs are case-sensitive.
- Python `.venv` inside `LanggraphR/inst/server/` is untracked; rebuild with
  `LanggraphR/scripts/setup_server.ps1` or `uv sync` if missing.
- R 4.6.1 with langgraphr installed; shiny is 1.14.0 (removed
  `renderVerbatimTextOutput()` and `verbatimTextOutput(fill=)`).
- Deleted (user decision): `agent_example/` demo apps and `examples/`.
