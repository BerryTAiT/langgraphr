# langgraphr

> Agentic AI for R, powered by LangGraph.

Build AI agents whose "hands" are R. The LLM decides what to do, and your R functions, data frames, models and plots do the work — all in pure R, no Python code required.

---

## Two Ways to Build

### Assistant Path — Quick Start

Register R functions as tools and chat with an LLM agent. The agent decides when to call your tools.

```r
library(langgraphr)

agent <- lg_connect()

top_products <- function(data, n = 3) {
  head(data[order(data$revenue, decreasing = TRUE), ], n)
}

agent$add_tool(top_products,
  description = "Return the top-N products by revenue from a data frame")

result <- agent$invoke("What are the top 2 products by revenue?")
result$content
```

### Graph Authoring Path — Full Control

Build custom stateful graphs where every node is an R function. No LLM needed — this is a pure state machine.

```r
g <- lg_graph("countdown",
  state = list(count = list(type = "number", reducer = "overwrite")))

step <- function(state) {
  n <- state$count
  if (is.null(n)) n <- as.numeric(state$input)
  if (n - 1 > 0) list(updates = list(count = n - 1), goto = "step")
  else            list(updates = list(count = 0))
}

graph <- g |> lg_add_node("step", step) |> lg_compile()
graph$invoke("5")$state$count
# 0
```

---

## Features

- **Real LangGraph engine** — production-grade graph runtime, not a reimplementation
- **Pure R API** — you never write or see Python code
- **Your data stays in R** — tool arguments cross the wire, but your data frames, models, and environments stay in R memory
- **Conversation memory** — thread-based persistence with optional SQLite durability
- **Any OpenAI-compatible model** — OpenAI, DeepSeek, Ollama, vLLM, and more
- **Network resilient** — auto-detects system proxies, retries on alternate routes, falls back to an in-R relay when VPNs break Python's TLS
- **Two paths in one package** — quick assistant agents and full graph authoring
- **Shiny-compatible** — build interactive chat UIs with Shiny (see example projects)

---

## Installation

```r
# Install the R package
remotes::install_local("LanggraphR")
```

Then set up the Python server (run once from the repo root):

```powershell
LanggraphR/scripts/setup_server.ps1
```

See the [full installation guide](vignettes/installation.Rmd) for details.

---

## Quick Example

```r
library(langgraphr)

# Set your model credentials (or use .Renviron)
Sys.setenv(LANGGRAPHR_API_KEY = "your-key")
Sys.setenv(LANGGRAPHR_MODEL = "deepseek-chat")
Sys.setenv(LANGGRAPHR_BASE_URL = "https://api.deepseek.com")

# Connect — starts the hidden server automatically
agent <- lg_connect()

# Register an R function as a tool
fibonacci <- function(n) {
  if (n <= 1) return(n)
  fibonacci(n - 1) + fibonacci(n - 2)
}

agent$add_tool(fibonacci,
  description = "Compute the nth Fibonacci number")

# Chat
result <- agent$invoke("What is the 10th Fibonacci number?")
cat(result$content)
```

---

## Documentation

- **[Quick Start](vignettes/quickstart.Rmd)** — get up and running in 5 minutes
- **[Installation](vignettes/installation.Rmd)** — prerequisites and setup
- **[Assistant Agents](vignettes/assistant-agents.Rmd)** — build LLM agents with R tools
- **[Graph Authoring](vignettes/graph-authoring.Rmd)** — custom stateful graphs in pure R
- **[Memory & Threads](vignettes/memory-and-threads.Rmd)** — conversation memory and persistence
- **[Tools & Models](vignettes/tools-and-models.Rmd)** — tool schemas and direct model calls
- **[Architecture](vignettes/architecture.Rmd)** — how it works under the hood
- **[FAQ & Troubleshooting](vignettes/faq.Rmd)** — common questions and fixes

Run `lg_tour()` for an interactive guided tour:

```r
library(langgraphr)
lg_tour()
```

---

## How It Works

langgraphr runs a hidden FastAPI server in the background that hosts the real LangGraph engine. When LangGraph needs to execute a tool or a graph node, it calls `interrupt()` — pausing the run and handing control back to R. R executes your function locally and resumes the run via HTTP.

```
R code  ◄────── HTTP (localhost) ──────►  Python sidecar
  │                                          │
  └─ Your R functions run here               └─ Real LangGraph engine
     (tools, nodes, data frames)                LLM calls, graph orchestration
```

This interrupt-resume pattern is built on LangGraph's native human-in-the-loop feature — R is the "human in the loop."

Learn more in the [Architecture guide](vignettes/architecture.Rmd).

---

## Requirements

| Component | Minimum version |
|---|---|
| R | 4.1 |
| Python | 3.10 |

**R dependencies:** R6, cli, httr2, jsonlite, processx

**Python dependencies:** fastapi, uvicorn, langgraph, langchain-core, langchain-openai, langgraph-checkpoint-sqlite

---

## Status

Version **0.3.0** — active development.

The core features (assistant path, graph authoring, memory, tool schemas) are working and tested. Some advanced LangGraph features (parallel Send, SSE streaming) are on the roadmap.

---

## License

MIT
