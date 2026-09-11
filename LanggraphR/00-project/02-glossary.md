# 02 — Glossary

| Term | Meaning |
|---|---|
| **Agent** | A program that uses an LLM (or rules) to decide and act toward a goal. In this project, agents are graphs. |
| **Graph** | A network of **nodes** connected by flow rules. Execution moves node to node until it ends. The core concept of LangGraph. |
| **Node** | One step of work. In langgraphr a node body is an **R function**. |
| **Edge** | A static default link: after node A, go to node B. |
| **Goto** | The dynamic next-node choice returned by an R node function at runtime (overrides the default edge). This is how branching and loops are expressed from R. |
| **Conditional edge** | LangGraph term for choosing the next node by logic. Here the logic IS the R node returning a `goto`. |
| **Entry node** | The first node executed when a graph run starts. |
| **State** | The data carried through the graph, split into named **channels**. |
| **Channel / field** | A named piece of state, e.g. `messages`. Each field declares a **reducer**. |
| **Reducer** | How a node's update merges into existing state: `overwrite` (replace) or `append` (add to list). |
| **Reducer (LangGraph)** | Same idea, implemented server-side per channel. |
| **Thread** | A named, persistent conversation/run history. Memory = reuse the same thread id. |
| **Checkpointer** | The server component that saves state after every step so runs can pause/resume (threads). |
| **Interrupt** | A LangGraph mechanism that pauses a run and hands control back to the caller. langgraphr uses it as the R↔server bridge. |
| **Resume** | Continuing an interrupted run by supplying the result. |
| **Bridge** | The mechanism connecting server execution to R: interrupt → R runs code → resume. |
| **R-tool / R-node** | A Python-visible slot whose actual logic is an R function. |
| **Graph spec** | The JSON description of a graph (nodes, edges, state) produced by the R DSL and consumed by the server. |
| **DSL** | Domain-specific language: the R functions (`lg_graph`, `lg_add_node`, ...) used to describe a graph. |
| **Compiler** | The R code that turns a DSL description into a validated graph spec. |
| **Hidden server** | The FastAPI + LangGraph process auto-spawned in the background. |
| **Runtime** | The Python code that compiles a graph spec into a real LangGraph graph. |
| **Tool** | A callable an agent may invoke. In langgraphr, always an R function. |
| **Multi-agent** | One agent using other agents (sub-graphs) as its tools. |
| **`__end__`** | Sentinel meaning "the graph run is finished." |
