# 05 — Libraries

Every library below, with the reason it is needed. Versions are lower bounds;
`uv sync` resolves current compatible versions and writes `uv.lock`.

## R package — `langgraphr/DESCRIPTION`
| Package | Why |
|---|---|
| `R6` (>= 1.0) | R6 classes for the agent and graph objects (mutable, methods) |
| `httr2` (>= 1.0) | Modern HTTP client: requests, JSON bodies, SSE streaming later |
| `processx` (>= 3.8) | Spawn/monitor/kill the hidden server subprocess |
| `cli` (>= 3.6) | User-facing messages, progress, errors |
| Suggests: `testthat` (>= 3) | Unit tests |

Note: `jsonlite` is used by the *examples* (data to JSON) and by users, but the
package itself relies on httr2 for JSON encoding; model calls from R nodes use
`httr2` directly (OpenAI-compatible REST).

## Hidden server — `langgraphr/inst/server`
| Package | Why |
|---|---|
| `fastapi` (>= 0.110) | HTTP API of the hidden server |
| `uvicorn[standard]` (>= 0.29) | ASGI runner for FastAPI |
| `langgraph` (>= 1.0) | The real graph engine (MIT) |
| `langchain-core` (>= 1.0) | Message types and tool abstractions |
| `langchain-openai` (>= 1.0) | OpenAI-compatible chat model binding (assistant path) |
| `pydantic` (>= 2.6) | Request validation (comes with fastapi) |
| `langgraph-checkpoint-sqlite` (optional) | Durable memory when `LANGGRAPHR_DB` is set |

## Tooling (not shipped)
| Tool | Why |
|---|---|
| `uv` (>= 0.5) | One-command isolated Python env + dependency resolution |
| `R` (>= 4.2) | Runtime for the R package |
| Python >= 3.10 | Runtime for the hidden server |
| `Rscript` / `R CMD` | Build, check, test the R package |

## License notes
All Python engine dependencies are MIT/Apache-compatible open source
(LangGraph is MIT), so bundling a runtime is permitted. This project: MIT.
