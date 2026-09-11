# langgraphr

> Agentic AI for R, powered by LangGraph.

[![R-CMD-check](https://github.com/BerryTAiT/langgraphr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/BerryTAiT/langgraphr/actions/workflows/R-CMD-check.yaml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LanggraphR/LICENSE)

Build AI agents and stateful workflows in **100% R**. The LLM decides what to do; your R functions, data frames, models and plots do the work. Under the hood, a hidden Python sidecar runs the real LangGraph engine — you never write or see Python code.

**Start with the package guide: [LanggraphR/README.md](LanggraphR/README.md)**

---

## Repository map

| Path | What it is |
|---|---|
| [`LanggraphR/`](LanggraphR/) | The `langgraphr` R package — DSL, compiler, agent classes, HTTP client |
| [`LanggraphR/inst/server/`](LanggraphR/inst/server/) | Hidden FastAPI sidecar hosting the real LangGraph engine |
| [`LanggraphR/vignettes/`](LanggraphR/vignettes/) | Full documentation source (quickstart, graph authoring, RAG patterns, …) |
| [`projects/`](projects/) | Six example AI apps built with the package |
| [`diagrams/`](diagrams/) | Architecture diagrams (Mermaid source — paste into mermaid.live) |
| [`langgraphr-presentation/`](langgraphr-presentation/) | Standalone HTML presentation about the project |

---

## Quick start

```r
# 1. Install the package (from a clone of this repo)
remotes::install_local("Langgraphr")
```

```powershell
# 2. Set up the hidden Python server (run once, from the repo root)
LanggraphR/scripts/setup_server.ps1
```

```r
# 3. Configure credentials — copy .env.example to a project folder and fill it in
#    (LANGGRAPHR_MODEL, LANGGRAPHR_BASE_URL, LANGGRAPHR_API_KEY)

# 4. Build an agent in R
library(langgraphr)

agent <- lg_connect()
agent$add_tool(function(n) sum(1:n), description = "Sum the integers 1..n")
agent$invoke("What is the sum of 1 to 100?")$content
```

Full walkthrough, including the graph-authoring path: [LanggraphR/README.md](LanggraphR/README.md).

---

## Example apps (`projects/`)

| Project | What it demonstrates |
|---|---|
| [`react_agent`](projects/react_agent/) | ReAct agent with a Shiny chat UI; live REASON/ACT/OBSERVE streaming, file uploads (CSV/PDF), 7 R tools |
| [`r_chatbot`](projects/r_chatbot/) | Minimal console + Shiny chatbot sharing one brain; persistent SQLite memory |
| [`rag_chat`](projects/rag_chat/) | Conversational RAG: upload documents, background indexing, cited answers, per-chat persistence, guardrail node |
| [`data_detective`](projects/data_detective/) | Data-analysis agent: upload data, ask questions, get charts back |
| [`code_reviewer`](projects/code_reviewer/) | Code-review assistant that reads and critiques R scripts |
| [`autopatch`](projects/autopatch/) | Code modernization engine: scan → patch via nested worker subgraph → human approval gate → PR bundles |

---

## Configuration

Each app reads model settings from its own `projects/<app>/.env` (git-ignored — see [.env.example](.env.example)):

| Variable | Purpose |
|---|---|
| `LANGGRAPHR_MODEL` | Model name (e.g. `deepseek-chat`, `gpt-4o-mini`) |
| `LANGGRAPHR_BASE_URL` | Any OpenAI-compatible endpoint (OpenAI, DeepSeek, Ollama, vLLM…) |
| `LANGGRAPHR_API_KEY` | Provider API key |
| `LANGGRAPHR_DB` | Optional SQLite file for durable memory across restarts |

**Security note:** `.env` files are deliberately excluded from version control. Keep real keys there; if a key ever lands in git history, rotate it with your provider.

---

## Learning path

1. [LanggraphR/README.md](LanggraphR/README.md) — the two ways to build (assistant vs. graph authoring)
2. [LanggraphR/vignettes/quickstart.Rmd](LanggraphR/vignettes/quickstart.Rmd) → [graph-authoring.Rmd](LanggraphR/vignettes/graph-authoring.Rmd) → [architecture.Rmd](LanggraphR/vignettes/architecture.Rmd)
3. Pick an app in [`projects/`](projects/) and read its source
4. [diagrams/](diagrams/) — visual map of how one `invoke()` call works

---

## License

[MIT](LanggraphR/LICENSE)
