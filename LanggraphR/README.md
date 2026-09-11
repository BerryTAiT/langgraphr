# langgraphr

**Agentic AI for R, powered by LangGraph.** Build AI agents whose "hands"
are R: the LLM decides what to do, and your R functions, data frames,
models and plots do the work. The LangGraph engine runs invisibly as a
local background server — you never write Python.

## Features

- **Assistant agents with R tools** — register any R function as a tool
  the LLM can call (`lg_connect()` + `agent$add_tool()`).
- **Custom stateful graphs in pure R** — author multi-step agent
  workflows with `lg_graph() |> lg_add_node() |> lg_compile()`; node
  bodies are R, orchestration is real LangGraph (loops, branching,
  reducers).
- **Multi-agent systems** — graphs calling graphs, no model or API key
  needed for the pure-graph path.
- **Thread memory** — conversations persist per thread; optional SQLite
  durability with `lg_use_sqlite()`.
- **Any OpenAI-compatible model** — OpenAI, DeepSeek, Ollama, vLLM and
  more via environment variables.
- **Zero-config networking** — automatic VPN/proxy-resilient model
  connectivity: the package detects your system proxy, retries alternate
  routes, and (as a last resort) relays model traffic through R's own
  HTTP stack. It works whether your VPN is on or off, on Windows, macOS
  and Linux, with no VPN configuration needed.

## Installation

```r
# 1. Install the package
remotes::install_local("langgraphr")

# 2. One-time: install the hidden server's Python dependencies
#    (only needed if `uv` is not installed; uv creates the environment
#    on demand automatically)
scripts/setup_server.ps1   # Windows
```

Requirements: R >= 4.1 and Python >= 3.10 (or [uv](https://docs.astral.sh/uv/)).

## Configure a model

Set environment variables (e.g. in `.Renviron`, or a `.env` file with
`dotenv::load_dot_env()`):

```
LANGGRAPHR_MODEL=deepseek-v4-flash
LANGGRAPHR_API_KEY=sk-...
LANGGRAPHR_BASE_URL=https://api.deepseek.com
```

`LANGGRAPHR_BASE_URL` is optional (defaults to OpenAI). Never commit
API keys — keep them in `.env` or `.Renviron`.

## Quickstart: an assistant with R tools

```r
library(langgraphr)

agent <- lg_connect()

top_products <- function(products, n = 3) {
  head(products[order(products$revenue, decreasing = TRUE), , drop = FALSE], n)
}
agent$add_tool(top_products, description = "Return the top-N products by revenue")

res <- agent$invoke("Here is today's sales data: ... which products are top?")
cat(res$content)
```

See `examples/quickstart.R` (assistant path) and
`examples/multi_agent.R` (graph path, needs **no** model or API key).

## Quickstart: a custom graph in pure R

```r
countdown <- lg_graph("countdown",
  state = list(count = list(type = "number", reducer = "overwrite")))

count_step <- function(state) {
  n <- state$count %||% as.numeric(state$input)
  if (n - 1 > 0) list(updates = list(count = n - 1), goto = "step") else
                  list(updates = list(count = n - 1))
}

countdown |>
  lg_add_node("step", count_step) |>
  lg_compile() |>
  (\(g) g$invoke("3"))()
```

## How it works

R is the developer surface; a hidden FastAPI sidecar runs the real
LangGraph engine on 127.0.0.1. When Python needs R code (a tool call or
a graph node), the run *pauses* via LangGraph's `interrupt()`, R executes
the function locally, and the run resumes over HTTP. Your R code and data
never leave your machine.

```
R session                          hidden Python sidecar
-----------                        ----------------------
lg_connect()  ──────spawn──────▶  uvicorn (port 8123)
agent$invoke() ────HTTP──────▶   LangGraph engine
   ▲                                │
   └──── interrupt: run this  ◀─────┘
         R function, then resume
```

## Development

```r
testthat::test_local("langgraphr")   # full suite, no API key needed
roxygen2::roxygenise("langgraphr")   # regenerate docs
```

MIT License.
