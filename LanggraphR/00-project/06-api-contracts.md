# 06 — API Contracts

## A. R public API (exports)

Lifecycle:
```r
lg_start_server(port = 8123L, wait = TRUE, timeout = 60L, logfile = NULL)
lg_stop_server()
lg_connect(port = 8123L, thread_id = NULL)   # returns LgAgent
lg_thread_id()                                # fresh thread id
```

Agent path (R6 `LgAgent`):
```r
agent$add_tool(fn, name = NULL, description = "", parameters = NULL)
agent$invoke(input, max_rounds = 10L)         # returns list(status, content, interrupts)
agent$reset()                                  # new thread id (clears memory)
```

Model helper (for R nodes that want an LLM):
```r
lg_call_model(messages, model = NULL, base_url = NULL, api_key = NULL, ...)
```

Graph path (full authoring):
```r
lg_graph(id, state = list(...), entry = NULL)      # builder object
g |> lg_add_node(id, fn)                            # fn(node_input) -> list(updates=, goto=)
g |> lg_add_edge(from, to)                          # default edge
g |> lg_set_memory(db_path = NULL)                  # optional sqlite
graph <- lg_compile(g)                              # registers spec; returns LgGraph
graph$invoke(input, thread_id = NULL)               # returns list(status, state, ...)
graph$reset()
```

State spec (in `lg_graph`):
```r
state = list(
  messages = list(type = "list", reducer = "append"),
  answer   = list(type = "str",  reducer = "overwrite")
)
```

## B. HTTP contract (server → R client)
All JSON on 127.0.0.1. Error bodies: `{detail: msg}`.

| Method & path | Body | Returns |
|---|---|---|
| `GET /health` | | `{status:"ok"}` |
| `GET /agents` | | `{agents:["assistant"]}` |
| `GET /graphs` | | `{graphs:[ids]}` |
| `POST /tools/register` | `{name,description,parameters}` | `{ok:true}` |
| `GET /tools` / `DELETE /tools/{name}` | | `{tools:[...]}` / `{ok:true}` |
| `POST /graphs/register` | graph spec (see 07) | `{ok:true, graph_id}` |
| `POST /threads/{id}/runs` | `{input, agent="assistant"|graph_id}` | run result |
| `POST /threads/{id}/resume` | `{value:<any>}` | run result |

Run result (both paths):
```json
{ "status": "completed" | "interrupted",
  "content": "text or null",            // assistant path: final text
  "state": {...} | null,                // graph path: final state
  "interrupts": [ {"node": "...", "state": {...}} ] | [ {"name","args","call_id"} ]
}
```

## C. Resume value contracts
- Assistant tool interrupt: R replies `{results: [<tool result per call>]}`.
- Graph node interrupt: R replies `{reply: {goto: "<node>|__end__|null",
  updates: {field: value}}}`.

## D. Error contract
R sees errors as `cli` errors with one clear message. The server wraps Python
exceptions; R hides traces (see 09).
