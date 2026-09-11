# 03 — Architecture

## 1. System overview

```
R DEVELOPER (100% R)
  graph <- lg_graph("g", state=list(...)) |>
           lg_add_node("step_a", fn_a) |> lg_add_edge("step_a","step_b")
  agent  <- lg_connect()$add_tool(fn)
  agent$invoke("...") / graph$invoke(input, thread="t1")
        │
        ▼  (1) DSL builds a graph spec (plain R lists)
R compiler  (2) validates spec, POST /graphs/register
        │
        ▼
HIDDEN SERVER  (uvicorn, auto-spawned by lg_start_server, auto-stopped)
  app.py        FastAPI: /health /tools /graphs /threads/{id}/runs /resume
  registry.py   stores tool schemas + graph specs (thread-safe)
  runtime.py    compiles each graph spec into a REAL LangGraph StateGraph;
                assistant agent uses langchain ChatOpenAI
  bridge flow   LangGraph node hits an R node/tool → interrupt({node|tool, state})
        │
        ▼  (3) R executes the actual R function in the R session
R runtime      (4) R resumes with {reply: {goto, updates}} or tool results
        │
        ▼  (5) LangGraph continues; loop until graph ends
```

## 2. Two developer paths

| Path | Purpose | R API |
|---|---|---|
| **Agent path** | Quick: LLM agent that can call R tools | `lg_connect()`, `agent$add_tool(fn)`, `agent$invoke()` |
| **Graph path** | Full authoring: your own node logic, branching, loops, multi-step | `lg_graph() |> lg_add_node() |> ... |> compile`, `graph$invoke()` |

The graph path is the "full power" surface. Node bodies and tool bodies are R
functions. Control flow between nodes is decided by R: a node returns
`list(goto = "next_node", updates = list(...))`, or just `list(updates=...)` to
follow the default edge registered in the DSL.

## 3. The bridge (how R code executes inside a LangGraph run)

1. Server reaches an R-backed node and calls LangGraph `interrupt(payload)`;
   payload = `{node: <id>, state: <current state>}` (tools: `{calls:[...]}`).
2. The run pauses; the server returns `status: "interrupted"` with payloads.
3. The R client executes the matching R function locally (full closure env).
4. The R client POSTs `/threads/{id}/resume` with the result.
5. `interrupt()` returns that result inside the node; the node issues
   `Command(goto=..., update=...)`; LangGraph applies reducers and continues.

Because the R client always initiates HTTP and the server never calls back
into R, there is no deadlock and no second R process is needed.

## 4. Memory model
- Conversation and graph-run memory = LangGraph **checkpointer** keyed by
  `thread_id`. R passes `thread_id` on every invoke; same id = same memory.
- In-process `MemorySaver` is default; a SQLite checkpointer is enabled when
  the `LANGGRAPHR_DB` env var is set (best-effort, version-guarded).

## 5. Design decisions (D)
| # | Decision | Why |
|---|---|---|
| D1 | Interrupt-based bridge, no inbound webhook | No R single-thread deadlock; closures run in the caller's env |
| D2 | Custom thin FastAPI server (not LangGraph Platform) | Full control of dynamic graph/tool registration; MIT-only stack; no Docker |
| D3 | Graph specs as JSON; server compiles them to real StateGraphs | R DSL stays pure R; Python side is generic and testable |
| D4 | Control flow via R `goto`, not python predicates | Branch/loop logic is R code, satisfying "full power of R" |
| D5 | LLM access two ways: bundled assistant (langchain) or `lg_call_model()` from R nodes | R-native option keeps model calls inside R logic; no Python needed |
| D6 | Everything commented per line; MD files are the source of truth | User requirement; keeps docs and code identical |

## 6. Limits (documented honestly)
- State crossing the bridge must be JSON-serializable.
- One node = one R call per visit; heavy compute should stay inside one call.
- Parallel `Send` fan-out and SSE streaming are roadmap, not this build.
