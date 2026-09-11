# bridge.py - run a run, return clean results to R.
#
# This layer knows the HTTP-facing result contract:
#   completed   -> {status, content?, state?}
#   interrupted -> {status, interrupts: [{node?, name?, args?, state?...}]}
# The R client reads "interrupted", does the R work, then POSTs /resume.

# Future-import enables newer type syntax on Python 3.10.
from __future__ import annotations

# The message types we look at when summarising assistant results.
from langchain_core.messages import AIMessage, HumanMessage
# Command resumes an interrupted run at the exact paused point.
from langgraph.types import Command

# Runtime builders and caches live in runtime.py.
from runtime import get_assistant_graph, get_graph


def _config(thread_id: str) -> dict:
    """Build the LangGraph config dict for one thread."""
    # LangGraph reads thread_id from config["configurable"].
    return {"configurable": {"thread_id": thread_id}}


def _safe(d: dict) -> dict:
    """Drop internal LangGraph keys from a state dict."""
    # Keep only keys that do not start with a double underscore.
    return {k: v for k, v in d.items() if not k.startswith("__")}


def _collect_interrupts(final_state: dict) -> list[dict]:
    """Extract our payloads from the __interrupt__ channel of a state."""
    # Read the pending interrupts (absent/empty when the run finished).
    pending = final_state.get("__interrupt__") or ()
    # This list collects one flat payload dict per interrupt.
    out = []
    # Loop over every pending Interrupt object.
    for item in pending:
        # Each interrupt carries the value our node passed to interrupt().
        value = getattr(item, "value", None) or {}
        # Values may be lists of requests (tools) or a single request dict.
        if isinstance(value, dict) and "calls" in value:
            # Assistant tool interrupts: extend with each tool request.
            out.extend(value["calls"])
        else:
            # Graph node interrupts: keep the single payload dict.
            out.append(value)
    # Return the flattened list of payload dicts.
    return out


def _last_ai_text(state: dict) -> str:
    """Return the text of the last assistant message, or empty."""
    # Scan messages from the end towards the start.
    for msg in reversed(state.get("messages", [])):
        # Only AIMessages carry the assistant's final answer text.
        if isinstance(msg, AIMessage):
            # Convert any content form into a string and return it.
            return str(msg.content or "")
    # No assistant message found.
    return ""


# ---------------------------------------------------------------------------
# Assistant path
# ---------------------------------------------------------------------------
def run_assistant(thread_id: str, input_text: str | None = None,
                  resume_value=None) -> dict:
    """Run (or resume) the bundled assistant; return a result dict."""
    # Load the compiled assistant graph (raises on model config errors).
    graph = get_assistant_graph()
    # Build the LangGraph config for this thread.
    config = _config(thread_id)
    # Invoke or resume depending on what the caller supplied.
    if resume_value is not None:
        # Resume the paused run with the R tool results.
        final = graph.invoke(Command(resume=resume_value), config)
    elif input_text is not None:
        # Start a new run with the user's message as the first input.
        final = graph.invoke(
            {"messages": [HumanMessage(content=input_text)]}, config)
    else:
        # Both missing is a programming error on the caller's side.
        raise ValueError("input_text or resume_value is required")

    # Collect any pending interrupts from the returned state.
    interrupts = _collect_interrupts(final)
    # Interrupted runs hand control to R and stop here.
    if interrupts:
        return {"status": "interrupted", "content": None,
                "interrupts": interrupts}
    # Completed runs report the assistant's final text.
    return {"status": "completed",
            "content": _last_ai_text(final),
            "interrupts": [],
            "messages": len(final.get("messages", []))}


# ---------------------------------------------------------------------------
# Developer-graph path
# ---------------------------------------------------------------------------
def run_graph(graph_id: str, thread_id: str,
              input_text: str | None = None,
              resume_value=None) -> dict:
    """Run (or resume) a developer-authored graph; return a result dict."""
    # Load the compiled graph for this id (raises when unknown).
    graph = get_graph(graph_id)
    # Build the LangGraph config for this thread.
    config = _config(thread_id)
    # Invoke or resume depending on what the caller supplied.
    if resume_value is not None:
        # Resume the paused node with the R node's reply.
        final = graph.invoke(Command(resume=resume_value), config)
    elif input_text is not None:
        # Start the graph by placing the input text into the input channel.
        final = graph.invoke({"input": input_text}, config)
    else:
        # Both missing is a programming error on the caller's side.
        raise ValueError("input_text or resume_value is required")

    # Collect any pending node interrupts from the returned state.
    interrupts = _collect_interrupts(final)
    # Interrupted runs hand the node payloads to R and stop here.
    if interrupts:
        return {"status": "interrupted", "content": None,
                "interrupts": interrupts, "state": None}
    # Completed runs report the final state (JSON-safe).
    return {"status": "completed", "content": None,
            "interrupts": [], "state": _safe(final)}
