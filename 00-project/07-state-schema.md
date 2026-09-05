# 07 — State Schema

State is the data that flows through a graph. It is a set of named **fields**
(channels). This file defines what fields are allowed and how updates merge.

## Field spec (R DSL → graph spec JSON)
```r
state = list(
  <field> = list(
    type     = "str" | "number" | "boolean" | "list" | "any",
    reducer  = "overwrite" | "append",     # default "overwrite"
    description = "optional text"
  )
)
```

Graph spec JSON form:
```json
{ "graph_id": "g", "state": {
    "messages": {"type": "list", "reducer": "append"},
    "answer":   {"type": "str",  "reducer": "overwrite"} },
  "nodes": [ {"id": "step_a"}, {"id": "step_b"} ],
  "entry": "step_a",
  "edges": [ {"from": "step_a", "to": "step_b"} ],
  "defaults": { "step_a": "step_b" } }
```

## Reducers
| Reducer | Rule | LangGraph implementation |
|---|---|---|
| `overwrite` | New value replaces old value | plain assignment per run |
| `append` | New value is appended to the existing list | `operator.add` on lists via `Annotated` |

## Node contract (R side)
Each node function receives the current state (a named list) and returns a
named list:
```r
function(state) {
  # ...do work in R...
  list(updates = list(answer = "done"), goto = "next_or_...__end__")
}
```
`updates` keys must match declared fields. `goto` is optional: when `NULL`
the default edge is used; set `"__end__"` to finish; set another node id to
branch/loop.

## Reserved channels
| Channel | Meaning |
|---|---|
| `input` | Initial text passed by `graph$invoke(input, ...)`; overwrite reducer |
| `messages` | Optional human-facing history if declared with `append` |

## JSON transport rules
- Values crossing the bridge are JSON: strings, numbers, booleans, null,
  arrays, plain objects. Data frames are converted to arrays of row objects.
- Unsupported (live connections, external pointers) must not be placed in
  state — compute inside one R call and store results.

## Validation
The server rejects a graph spec when: a node id is missing/duplicated, a state
reducer is not one of the two allowed, the entry node is unknown, or an edge
references an unknown node. The R compiler performs the same checks first so
errors surface in R, not Python (see 09).
