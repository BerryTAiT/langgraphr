# 01 — Vision

## What we are building
**langgraphr**: an R package that lets R developers author any kind of agentic
application entirely in R — custom graphs, branches, loops, tools, memory,
multi-agent setups — while the real LangGraph engine runs as a **fully hidden**
local server. The user never installs, writes, sees, or reasons about Python.

## Why
- The agent wave is Python-shaped; R users (finance, pharma, bio, analytics)
  are told "just use Python." This removes that wall.
- R strengths (data frames, models, tidyverse) should be first-class agent
  capabilities, which is only possible when node/tool logic runs in R.
- LangGraph is MIT-licensed and battle-tested; reimplementing it in R is the
  wrong bet. We orchestrate it, we don't rebuild it.

## Goals (success criteria)
1. Developer writes 100% R: graph DSL, node functions, tools, memory config.
2. "Any agentic app you can build in Python LangGraph, you can build here" —
   for the documented feature set (see roadmap in `04-file-tree` / `08-build`).
3. Python is invisible: no Python files to edit, no Python errors leak
   (see `09-error-and-hiding`).
4. Every source line is commented in simple English, and the full commented
   code is pre-written in Markdown before real files are created.

## Non-goals (this build)
- Reimplementing the LangGraph engine in R.
- Parallel fan-out via LangGraph `Send` (documented as a later milestone).
- Streaming SSE into Shiny/Quarto (later milestone).
- Publishing to CRAN/R-universe (later milestone).

## Personas
- **Developer**: R user building agents with this package.
- **Maintainer**: the person who keeps this repo; reads specs + annotated MDs.
- **Runner**: installs the package on a machine with R but possibly no Python
  knowledge; the hidden server must "just work."
