# app.py - HTTP API of the hidden langgraphr server.
#
# Every endpoint is JSON. The R client is the primary consumer; any HTTP
# tool (curl, browser) can also be used for debugging. The contract is
# documented in 00-project/06-api-contracts.md.

# Future-import enables newer type syntax on Python 3.10.
from __future__ import annotations

# uuid creates fresh thread ids on the rare occasions the server does it.
import re
import uuid

# FastAPI pieces for the app, request models and error responses.
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

# Run orchestration (start/resume runs on both paths).
from bridge import run_assistant, run_graph
# Spec validation for graph registration.
from graph_spec import validate_graph_spec
# The process-wide registry of tools and graph specs.
from registry import registry
# Runtime helper that forgets a compiled graph on re-registration.
from runtime import drop_graph

# Create the FastAPI application object (uvicorn runs "app:app").
app = FastAPI(title="langgraphr server")

# Sets of thread ids and their run "kind" (assistant or a graph id).
# Used so /resume knows which kind of run it is continuing.
_threads: set[str] = set()
_thread_kind: dict[str, str] = {}


# ---------------------------------------------------------------------------
# Request/response models
# ---------------------------------------------------------------------------
class ToolIn(BaseModel):
    """Body of POST /tools/register."""
    name: str                    # tool name
    description: str = ""        # what the tool does (model guidance)
    parameters: dict = Field(default_factory=lambda: {  # JSON schema
        "type": "object", "properties": {}})


class GraphIn(BaseModel):
    """Body of POST /graphs/register."""
    spec: dict                   # the graph spec sent by the R compiler


class RunIn(BaseModel):
    """Body of POST /threads/{id}/runs."""
    input: str | None = None     # the user's message / graph input text
    agent: str = "assistant"     # "assistant" or a registered graph id


class ResumeIn(BaseModel):
    """Body of POST /threads/{id}/resume."""
    value: dict | list | str | float | int | bool | None = None


# ---------------------------------------------------------------------------
# Health / capabilities
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    """Trivial health probe used by lg_start_server()."""
    return {"status": "ok"}


@app.get("/agents")
def agents():
    """List runnable agents (the assistant plus registered graphs)."""
    # Report the assistant plus every registered graph id.
    return {"agents": ["assistant"] + sorted(registry.graph_ids())}


@app.get("/graphs")
def list_graphs():
    """List every registered developer graph id."""
    return {"graphs": sorted(registry.graph_ids())}


# ---------------------------------------------------------------------------
# Tool registry (schemas for R functions)
# ---------------------------------------------------------------------------
@app.post("/tools/register")
def register_tool(tool: ToolIn):
    """Register an R-only tool schema."""
    # OpenAI-style APIs require names to match ^[a-zA-Z0-9_-]+$. Sanitize
    # here so a malformed name from any client can never poison the shared
    # registry and break every subsequent request for all sessions.
    clean = re.sub(r"[^a-zA-Z0-9_-]", "_", tool.name) or "tool"
    if clean != tool.name:
        print(f"[langgraphr] sanitized tool name '{tool.name}' -> '{clean}'")
        tool.name = clean
    # Ask the registry to store the schema.
    registry.register_r_tool(tool.name, tool.description, tool.parameters)
    # Confirm success.
    return {"ok": True}


@app.get("/tools")
def list_tools():
    """List every registered tool schema."""
    return {"tools": registry.schemas()}


@app.delete("/tools/{name}")
def delete_tool(name: str):
    """Remove a registered tool."""
    registry.drop_tool(name)
    return {"ok": True}


# ---------------------------------------------------------------------------
# Graph registry (specs compiled by the R DSL)
# ---------------------------------------------------------------------------
@app.post("/graphs/register")
def register_graph(body: GraphIn):
    """Validate and register (or replace) a developer graph spec."""
    # Validate the spec; raises ValueError with an R-friendly message.
    try:
        spec = validate_graph_spec(body.spec)
    except ValueError as exc:
        # Turn validation failures into HTTP 400 errors.
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    # Register the spec (re-registering replaces the previous version so
    # iterating on R code and re-running examples never conflicts).
    registry.register_graph(spec)
    # Drop any previously compiled version so the next run rebuilds fresh.
    drop_graph(spec["graph_id"])
    # Confirm with the registered id.
    return {"ok": True, "graph_id": spec["graph_id"]}


# ---------------------------------------------------------------------------
# Threads
# ---------------------------------------------------------------------------
@app.get("/threads")
def list_threads():
    """List every thread id this server process has seen."""
    return {"threads": sorted(_threads)}


@app.post("/threads")
def create_thread():
    """Create a fresh thread id server-side (rarely needed)."""
    tid = uuid.uuid4().hex
    _threads.add(tid)
    return {"thread_id": tid}


def _remember_thread(thread_id: str, kind: str) -> None:
    """Record a thread id and which kind of run it belongs to."""
    _threads.add(thread_id)              # remember the id exists
    _thread_kind[thread_id] = kind       # remember assistant vs graph


# ---------------------------------------------------------------------------
# Runs and resume
# ---------------------------------------------------------------------------
@app.post("/threads/{thread_id}/runs")
def start_run(thread_id: str, run: RunIn):
    """Start a run of the assistant or a developer graph on a thread."""
    # Reject empty thread ids immediately.
    if not thread_id or not isinstance(thread_id, str):
        raise HTTPException(status_code=400, detail="thread_id required")
    # Dispatch by the requested agent type, translating any failure into a
    # readable HTTP error (never a raw traceback).
    try:
        if run.agent == "assistant":
            # The quick path: bundled LLM agent with R tools.
            _remember_thread(thread_id, "assistant")
            return run_assistant(thread_id, input_text=run.input)
        # Developer-graph path: verify the graph exists first.
        if registry.graph_spec(run.agent) is None:
            raise HTTPException(status_code=404,
                                detail=f"unknown graph '{run.agent}'")
        # Remember this thread belongs to this graph.
        _remember_thread(thread_id, run.agent)
        return run_graph(run.agent, thread_id, input_text=run.input)
    except HTTPException:
        # Already-clean HTTP errors pass straight through untouched.
        raise
    except Exception as exc:  # noqa: BLE001 - report cleanly, hide Python
        # Any other failure becomes a readable 500 for the R client.
        raise HTTPException(status_code=500,
                            detail=f"Agent run failed: {exc}") from exc


@app.post("/threads/{thread_id}/resume")
def resume_run(thread_id: str, resume: ResumeIn):
    """Resume an interrupted run with the R client's answer."""
    # Reject empty thread ids immediately.
    if not thread_id or not isinstance(thread_id, str):
        raise HTTPException(status_code=400, detail="thread_id required")
    # Look up which kind of run this thread belongs to.
    kind = _thread_kind.get(thread_id)
    # Refuse to resume threads we have never seen.
    if kind is None:
        raise HTTPException(status_code=404,
                            detail="unknown thread - start a run first")
    # Dispatch to the right runner, translating failures into readable errors.
    try:
        # Resume the assistant path when that is what started the thread.
        if kind == "assistant":
            return run_assistant(thread_id, resume_value=resume.value)
        # Otherwise resume the developer graph on that thread.
        return run_graph(kind, thread_id, resume_value=resume.value)
    except HTTPException:
        # Already-clean HTTP errors pass straight through untouched.
        raise
    except Exception as exc:  # noqa: BLE001 - report cleanly, hide Python
        # Any other failure becomes a readable 500 for the R client.
        raise HTTPException(status_code=500,
                            detail=f"Agent run failed: {exc}") from exc
