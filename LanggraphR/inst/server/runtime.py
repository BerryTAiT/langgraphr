# runtime.py - build and run LangGraph graphs for langgraphr.
#
# Two kinds of run exist:
#   1. assistant - a bundled LLM agent whose tools are R functions.
#   2. graph     - a developer-authored graph (from the R DSL) whose NODES
#                  are R functions; flow between nodes is decided in R by the
#                  "goto" value each node returns.
#
# Both use the same trick: when Python would need to run R code, the graph
# calls LangGraph interrupt() which pauses the run and hands control back to
# the R client over HTTP. The client later resumes the run and interrupt()
# returns the client's answer inside the node.

# Future-import makes the newer type syntax work on Python 3.10.
from __future__ import annotations

# 'operator' provides the list-append reducer for state channels.
import operator
# 'os' reads model/checkpoint configuration from environment variables.
import os
# 'sqlite3' backs the optional durable SqliteSaver checkpointer.
import sqlite3
# Typing helpers for dynamically-built state schemas.
from typing import Annotated, Any, Optional, TypedDict

# Message types for the assistant path.
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
# OpenAI-compatible chat model (assistant path only).
from langchain_openai import ChatOpenAI
# In-memory checkpointer (memory = threads while the server lives).
from langgraph.checkpoint.memory import MemorySaver
# Graph building blocks from LangGraph.
from langgraph.graph import END, START, StateGraph
# add_messages is the built-in list-append reducer for message lists.
from langgraph.graph.message import add_messages
# Command lets a node override its next step; interrupt pauses the run.
from langgraph.types import Command, interrupt

# Our own validated spec helpers and the process-wide registry.
from graph_spec import validate_graph_spec
from registry import registry

# Sentinel string the R DSL uses for "the graph is finished".
END_MARKER = "__end__"

# Maps our JSON-ish state types onto real Python types.
_TYPE_MAP = {
    "str": str,      # JSON string  -> Python str
    "number": float, # JSON number  -> Python float (int works too)
    "boolean": bool, # JSON boolean -> Python bool
    "list": list,    # JSON array   -> Python list
    "any": Any,      # anything     -> Python Any
}


def _clean_env(value: str | None) -> str | None:
    """Strip whitespace and stray backticks from an environment value.

    Users sometimes paste model config with markdown backticks around it
    (e.g. `https://api.deepseek.com`); accepting that is friendlier than
    failing with an obscure URL error.
    """
    # None passes straight through.
    if value is None:
        return None
    # Remove surrounding whitespace and any backtick characters.
    return value.strip().strip("`").strip()


# ---------------------------------------------------------------------------
# Model construction (assistant path)
# ---------------------------------------------------------------------------
def _build_llm():
    """Create the OpenAI-compatible chat model from environment variables."""
    # Model name; sensible default when nothing is configured.
    model = _clean_env(os.getenv("LANGGRAPHR_MODEL")) or "gpt-4o-mini"
    # Optional custom base URL (Ollama, DeepSeek, vLLM, ...).
    base_url = _clean_env(os.getenv("LANGGRAPHR_BASE_URL"))
    # Optional API key (falls back to OPENAI_API_KEY inside the SDK).
    api_key = _clean_env(os.getenv("LANGGRAPHR_API_KEY"))
    # Collect the keyword arguments for ChatOpenAI.
    kwargs = {"model": model}
    # Add the base URL only when one was configured.
    if base_url:
        kwargs["base_url"] = base_url
    # Add the api key only when one was configured.
    if api_key:
        kwargs["api_key"] = api_key
    # Bound the model call so a blackholed API route fails fast instead
    # of hanging the run: short connect timeout (lets the R client's
    # proxy/relay rescue engage), generous read time for generation.
    # Override via LANGGRAPHR_MODEL_TIMEOUT / LANGGRAPHR_CONNECT_TIMEOUT.
    try:
        import httpx  # openai dependency, always present
        kwargs["timeout"] = httpx.Timeout(
            float(os.getenv("LANGGRAPHR_MODEL_TIMEOUT", "120")),
            connect=float(os.getenv("LANGGRAPHR_CONNECT_TIMEOUT", "10")),
        )
    except Exception:
        kwargs["timeout"] = float(os.getenv("LANGGRAPHR_MODEL_TIMEOUT", "120"))
    # Construct and return the model object.
    return ChatOpenAI(**kwargs)


# ---------------------------------------------------------------------------
# Checkpointer factory (memory)
# ---------------------------------------------------------------------------
# A per-graph checkpointer instance is cached here so every thread of the
# same graph shares one memory store.
_saver_cache: dict[str, Any] = {}


def _make_checkpointer(graph_key: str):
    """Return a checkpointer for one graph, cached per graph id.

    Default: MemorySaver (threads live while the server runs).
    When LANGGRAPHR_DB points to a file and the optional sqlite saver is
    installed, a durable SqliteSaver is used instead.
    """
    # Return the cached saver when we already built one for this graph.
    if graph_key in _saver_cache:
        return _saver_cache[graph_key]
    # Read the optional database path from the environment.
    db_path = os.getenv("LANGGRAPHR_DB")
    # Local variable that will hold the chosen saver.
    saver = None
    # Only try sqlite when the user asked for a database file.
    if db_path:
        # Attempt to import the sqlite saver (optional dependency).
        try:
            from langgraph.checkpoint.sqlite import SqliteSaver  # type: ignore
            # Open a durable sqlite connection kept alive for the whole
            # server lifetime. check_same_thread=False is required because
            # requests arrive on different server threads.
            conn = sqlite3.connect(db_path, check_same_thread=False)
            # Build the saver directly from the connection. Newer versions
            # of SqliteSaver.from_conn_string() return a context manager
            # that would close the connection, so construct it directly.
            saver = SqliteSaver(conn)
        except Exception as exc:  # noqa: BLE001 - optional dep missing etc.
            # Print a warning to the server log and fall back to memory.
            print(f"[langgraphr] sqlite unavailable ({exc}); using memory")
    # No db path or sqlite failed: fall back to in-process memory.
    if saver is None:
        saver = MemorySaver()
    # Cache the saver for this graph id so threads share the same store.
    _saver_cache[graph_key] = saver
    # Return the chosen checkpointer.
    return saver


# ---------------------------------------------------------------------------
# Assistant graph (the quick path: LLM agent + R tools)
# ---------------------------------------------------------------------------
def _build_assistant_graph():
    """Build the bundled assistant graph (agent node + tools node)."""
    # Build the chat model up front; missing credentials raise here.
    llm = _build_llm()

    # agent node: ask the model, bound with every registered tool schema.
    def agent(state: dict) -> dict:
        # Read the message history from state.
        msgs = state["messages"]
        # Read the current tool schemas (may be empty).
        tools = registry.schemas()
        # Bind tools when any exist, otherwise call the model directly.
        if tools:
            return {"messages": [llm.bind_tools(tools).invoke(msgs)]}
        return {"messages": [llm.invoke(msgs)]}

    # tools node: run python tools locally; R tools pause via interrupt.
    def tools_node(state: dict) -> dict:
        # The model's last message decides what to execute.
        last = state["messages"][-1]
        # Read any tool calls on that message.
        calls = getattr(last, "tool_calls", None) or []
        # With no tool calls there is nothing for this node to do.
        if not calls:
            return {"messages": []}
        # Split calls into R-only and everything else.
        r_calls = [c for c in calls if registry.is_r_tool(c["name"])]
        # This list will hold the ToolMessages we produce.
        out = []
        # If any R tool was requested, pause the whole run once and ask R.
        if r_calls:
            # Build the payload the R client will see for each call.
            requests = [{"name": c["name"], "args": c["args"],
                         "call_id": c["id"]} for c in r_calls]
            # interrupt() pauses here and returns the client's answer.
            resume = interrupt({"calls": requests})
            # The R client answers with {results: [<result per call>]}.
            results = (resume or {}).get("results", [])
            # Zip results back onto their tool calls.
            for call, result in zip(r_calls, results):
                # Convert each result into a ToolMessage for the model.
                out.append(ToolMessage(content=_stringify(result),
                                       tool_call_id=call["id"]))
        # Handle python-local and unknown tools (never paused).
        python_names = registry.python_names()
        # Loop over every tool call again.
        for c in calls:
            # Python-local tools execute right here.
            if c["name"] in python_names:
                # Run the tool and wrap its output in a ToolMessage.
                out.append(ToolMessage(
                    content=_stringify(registry.call_python(c["name"],
                                                            c["args"])),
                    tool_call_id=c["id"]))
            # Unknown tools get a clear short message instead of crashing.
            elif not registry.is_r_tool(c["name"]):
                out.append(ToolMessage(content="unknown tool",
                                       tool_call_id=c["id"]))
        # Return every ToolMessage we produced.
        return {"messages": out}

    # route decides where to go after the agent node.
    def route(state: dict) -> str:
        # Look at the agent's last message.
        last = state["messages"][-1]
        # Tool calls mean we must run the tools node next.
        if getattr(last, "tool_calls", None):
            return "tools"
        # No tool calls means the answer is final.
        return END

    # Assemble the assistant graph structure.
    g = StateGraph(assistant_state_schema())   # state with a messages channel
    # Add the two nodes.
    g.add_node("agent", agent)
    g.add_node("tools", tools_node)
    # The run always starts in the agent node.
    g.add_edge(START, "agent")
    # From agent, route conditionally to tools or the end.
    g.add_conditional_edges("agent", route, {"tools": "tools", END: END})
    # After tools we always return to the agent.
    g.add_edge("tools", "agent")
    # Compile with a per-graph checkpointer (memory).
    return g.compile(checkpointer=_make_checkpointer("__assistant__"))


def assistant_state_schema() -> type:
    """Define the assistant state schema (a messages list with a reducer)."""
    # Build a dynamic TypedDict with one annotated channel.
    return TypedDict("AssistantState", {
        "messages": Annotated[list, add_messages],
    })


# ---------------------------------------------------------------------------
# Developer graph path (nodes are R functions)
# ---------------------------------------------------------------------------
def _graph_state_type(state_spec: dict) -> type:
    """Build a TypedDict type from a validated state spec."""
    # Collect one annotation per declared field.
    annotations: dict[str, Any] = {}
    # Loop over every field in the spec.
    for fname, fspec in state_spec.items():
        # Translate the JSON-ish type name to a Python type.
        base = _TYPE_MAP.get(fspec.get("type", "any"), Any)
        # append channels merge by adding lists together.
        if fspec.get("reducer") == "append":
            # Annotated[list, operator.add] means "concatenate updates".
            annotations[fname] = Annotated[list, operator.add]
        else:
            # Optional means the field may be absent at the start.
            annotations[fname] = Optional[base]
    # Always reserve an 'input' channel for the text each run receives.
    annotations.setdefault("input", Optional[str])
    # Build and return the dynamic TypedDict subclass.
    return TypedDict("GraphState", annotations)


def _stringify(value) -> str:
    """Turn any tool/node result into a stable string for messages."""
    # Strings pass through untouched.
    if isinstance(value, str):
        return value
    # Everything else is JSON-encoded so it reads cleanly.
    import json
    return json.dumps(value, default=str)


def _build_graph_from_spec(spec: dict):
    """Compile a validated graph spec into a real LangGraph graph."""
    # Remember the id (also the registry key and thread namespace).
    graph_id = spec["graph_id"]
    # Build the dynamic state type for this graph.
    state_type = _graph_state_type(spec["state"])
    # Extract useful short names from the spec.
    entry = spec["entry"]
    # Default next node per node id (missing = end).
    defaults = spec["defaults"]

    def make_node(node_id: str, default_to: str | None):
        """Create a LangGraph node that runs R via interrupt/resume."""
        # This closure captures the node id and its default target.
        def node(state: dict) -> Command:
            # Build the payload handed to R: which node and current state.
            payload = {"node": node_id, "state": _safe_state(state)}
            # Pause the run; R executes the node function and resumes.
            reply = interrupt(payload)
            # Normalise a missing answer to an empty reply.
            reply = (reply or {}).get("reply") or {}
            # Decide where to go next.
            goto = reply.get("goto")
            # Read the state updates the R node wants to apply.
            updates = reply.get("updates") or {}
            # Keep only declared channels; wrap append values as lists.
            clean = {}
            # Loop over every requested update.
            for key, value in updates.items():
                # Skip fields that are not part of the state schema.
                if key not in spec["state"] and key != "input":
                    continue
                # Append channels need a single-element list per update.
                fspec = spec["state"].get(key, {})
                if fspec.get("reducer") == "append":
                    clean[key] = [value]
                else:
                    # Overwrite channels replace the stored value.
                    clean[key] = value
            # Resolve the actual target node for the Command.
            target = goto or default_to
            # An explicit end marker, or no target at all, means stop.
            if target in (None, "", END_MARKER):
                # End the run, applying any final updates on the way out.
                return Command(goto=END, update=clean)
            # Otherwise continue at the chosen node.
            return Command(goto=target, update=clean)
        # Return the wrapped node function.
        return node

    # Create the StateGraph with our dynamic state type.
    g = StateGraph(state_type)
    # Add one LangGraph node per spec node.
    for node in spec["nodes"]:
        # Resolve the default successor (or None -> end).
        default_to = defaults.get(node["id"])
        # Register the interrupt-based node wrapper.
        g.add_node(node["id"], make_node(node["id"], default_to))
    # The graph always starts at the entry node.
    g.add_edge(START, entry)
    # NOTE: no static per-node edges. Every node wrapper ALWAYS returns a
    # Command(goto=...), so routing is fully Command-driven. With LangGraph
    # 1.x, adding a static edge from a node that also returns Command(goto)
    # makes the graph fan out to BOTH targets whenever the R node's goto
    # disagrees with its declared default edge (e.g. a self-cycle like
    # dispatch -> dispatch while defaults say dispatch -> gate). That
    # produces multiple simultaneous node interrupts, which the R client
    # cannot service (it would need interrupt ids on resume). Keeping the
    # graph edge-free besides START guarantees exactly one pending
    # interrupt per stop.
    # Compile with the per-graph checkpointer.
    return g.compile(checkpointer=_make_checkpointer(graph_id))


def _safe_state(state: dict) -> dict:
    """Return only JSON-friendly parts of the state for R."""
    # Keep the whole state except internal LangGraph keys.
    return {k: v for k, v in state.items()
            if not k.startswith("__")}


# ---------------------------------------------------------------------------
# Caches + run entry points (also used by bridge.py)
# ---------------------------------------------------------------------------
# Lazy caches so the server can boot without model credentials.
_assistant_cache = None
_graph_cache: dict[str, Any] = {}


def get_assistant_graph():
    """Return the compiled assistant graph (built once, lazily)."""
    global _assistant_cache
    # Build on first request; cache afterwards.
    if _assistant_cache is None:
        _assistant_cache = _build_assistant_graph()
    # Return the cached compiled graph.
    return _assistant_cache


def get_graph(graph_id: str):
    """Return the compiled graph for a registered spec (built lazily)."""
    # Return the cached compiled graph if we already built it.
    if graph_id in _graph_cache:
        return _graph_cache[graph_id]
    # Read the validated spec from the registry.
    spec = registry.graph_spec(graph_id)
    # Unknown graph ids are reported clearly.
    if spec is None:
        raise KeyError(f"unknown graph '{graph_id}'")
    # Compile the spec into a real LangGraph graph.
    graph = _build_graph_from_spec(spec)
    # Cache it so threads keep working across runs.
    _graph_cache[graph_id] = graph
    # Return the compiled graph.
    return graph


def reset_runtime_caches() -> None:
    """Forget compiled graphs and savers (used by tests and re-registration)."""
    global _assistant_cache
    # Clear the assistant graph cache.
    _assistant_cache = None
    # Clear every compiled developer graph.
    _graph_cache.clear()
    # Clear every cached checkpointer.
    _saver_cache.clear()


def drop_graph(graph_id: str) -> None:
    """Forget one compiled graph so its next run uses a fresh spec."""
    # Remove the compiled graph from the cache.
    _graph_cache.pop(graph_id, None)
    # Remove its checkpointer too (fresh memory store for the new spec).
    _saver_cache.pop(graph_id, None)
