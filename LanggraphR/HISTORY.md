# HISTORY.md — how langgraphr was created

This file documents the creation of the project: decisions, files, commands
run, and what was verified at each step. It is the "document the creation"
record requested for this build.

## 2026-09-05 — first live R run + fixes

- Full-authoring example (`multi_agent.R`) ran end-to-end in Positron with real
  R 4.6.1: DSL compile → hidden server start → R node loops via `goto` →
  state reducers → a graph calling a sub-graph. Confirmed working.
- Fixed launcher bug: relative python paths failed in `processx`
  (`server.R` now normalizes paths to absolute).
- Fixed graph re-registration: registering an existing graph id now replaces
  the old spec instead of returning HTTP 409 (iteration-friendly).
- Fixed tool-schema bug: R's "missing argument" object cannot be stored in a
  variable; `lg_tool_schema()` now tests it inline before storing the default
  (`schema.R`). Error was: argument "default" is missing.
- HTTP errors: R client now reads and displays the server's real error detail
  instead of a bare "HTTP 500 Internal Server Error" (added
  `httr2::req_error(is_error = FALSE)` in `client.R`); server wraps failures in
  readable 500s (`app.py`); server tolerates backticks around env values
  (`runtime.py` `_clean_env`). Released as 0.2.3.
- Tool naming + schemas: `agent$add_tool()` now resolves the tool name from
  the expression the user passed (was registering every tool as "fn"), and
  `quickstart.R` declares explicit schemas for data-frame arguments (array of
  objects). DeepSeek surfaced both issues with clear validation errors.
  Released as 0.2.4.
- Verified on real R for the first time: `R CMD INSTALL` + all 25 unit tests
  pass (`testthat`), tool-schema type inference confirmed.
- Upgraded everything to latest: uv 0.11.28, langgraph 1.2.11, langchain-core
  1.6.1, fastapi 0.141.1, R 4.6.1, R packages refreshed from CRAN.
- Added `scripts/update_all.ps1` so "always latest" is one command.
- Installed Rtools (latest on winget, 4.5.6768) via `winget install
  RProject.Rtools`; R 4.6.1 confirms `pkgbuild::has_build_tools() == TRUE`.

## 2026-09-04 — the build

### 0. Context
The developer wanted an R package that hides Python completely while giving R
users the full power of LangGraph for agentic applications. Requirements:
documentation of the creation itself, and every line of code commented in
simple English, with all code pre-written as Markdown.

### 1. Planning only (no files)
- Produced the plan in chat: scope (full-authoring vision), MD coverage
  (R + Python server + scripts), file tree, libraries, milestones, risks.
- Design decided: interrupt-based R↔server bridge (no inbound webhook,
  therefore no R single-thread deadlock); custom thin FastAPI server (no
  Docker); graph specs as JSON compiled server-side into real LangGraph
  StateGraphs; control flow decided by R node `goto` values.

### 2. Specs written (`00-project/01–09.md`)
Created nine spec documents: vision, glossary, architecture, file tree,
libraries, API contracts, state schema, build process, error/hiding policy.

### 3. Annotated code, MD-first
Wrote 16 annotated Markdown files (8 R, 5 Python, 3 PowerShell). Each carries
a `<!-- TARGET: path -->` marker and one fenced code block whose every line is
commented in simple English.

### 4. Real files generated
- Wrote `scripts/tools/extract_code.py` to turn annotated MDs into real files.
- Ran it: 16 files generated (R package sources, Python server, scripts).
- Wrote non-annotated files directly: package metadata (`DESCRIPTION`,
  `NAMESPACE`, `LICENSE`, `.Rbuildignore`), server metadata
  (`requirements.txt`, `pyproject.toml`, `.env.example`, server `README.md`),
  Python regression test, R unit tests, two examples, `.gitignore`.

### 5. Verification performed on this machine
- `uv sync`: installed 51 packages incl. langgraph 1.2.11, fastapi 0.141.1,
  langchain-core 1.6.1 (Python 3.11.15 in `.venv`).
- `python -m py_compile` on all five server modules: clean.
- `python tests/bridge_smoke.py`: **PASSED**
  - assistant path: tool interrupt returned `{name: add, args: {a:1,b:2}}`;
    resume completed with the final answer.
  - graph path: node `a` interrupt carried state, resume honoured
    `goto: b` + updates, node `b` completed; append reducer accumulated
    `log: [step-a, step-b]`, overwrite reducer set `counter: 2`.
- Live HTTP checks against a running uvicorn instance:
  - `GET /health` → `{status: ok}`
  - `POST /graphs/register` with a valid spec → registered; `GET /graphs`
    listed it.
  - `POST /graphs/register` with an invalid spec (unknown entry node) →
    clean HTTP 400 `entry node 'ghost' does not exist` (no Python traceback).
- Server was shut down cleanly afterwards.

### 6. Notes & decisions made during the build
- Reserved word `function` in R schemas: accessed/constructed with `[[ ]]`
  and backticks to stay valid R syntax (documented in code comments).
- FastAPI validation errors arrive as a list; the R client flattens them into
  a single readable line before aborting.
- The assistant graph is built lazily so the server can boot without model
  credentials; missing config surfaces only when a run is attempted.
- SQLite persistence is available via `lg_use_sqlite()`/`LANGGRAPHR_DB` and is
  best-effort (version-guarded); in-process memory is the default.

### 7. Remaining work (this machine has no R installed)
- `scripts/build_r_package.ps1` and `R CMD check` once R >= 4.2 is available.
- Run `examples/quickstart.R` with a real model key.
- Roadmap items (see `00-project/04-file-tree.md`): durable SQLite by default,
  parallel `Send` fan-out, SSE streaming, binary bundles, publishing.
