# bridge_smoke.py - no-network regression tests for langgraphr server.
#
# Covers BOTH run paths without any real model or network:
#   1. assistant path: a fake LLM proposes an R tool; the run must interrupt
#      with the tool request and complete after resume.
#   2. graph path: a registered spec runs R "nodes"; each node interrupt must
#      hand the right state to the caller and honour goto/updates on resume.
#
# Run from langgraphr/inst/server:
#     uv run python tests/bridge_smoke.py

# Make module imports work regardless of where the script is invoked from.
import os
import sys

# A fake key lets ChatOpenAI objects be constructed (never called).
os.environ["LANGGRAPHR_MODEL"] = "gpt-4o-mini"
os.environ["LANGGRAPHR_API_KEY"] = "sk-dummy"

# Compute the server folder (this file lives in <server>/tests/).
SERVER = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir))
# Put the server folder on the import path.
sys.path.insert(0, SERVER)

# AIMessage is what our fake model returns.
from langchain_core.messages import AIMessage  # noqa: E402


class FakeLLM:
    """A model stand-in: first call proposes an R tool, later calls answer."""

    def __init__(self, **kwargs):
        # Count how many times the fake model was invoked.
        self.calls = 0

    def bind_tools(self, schemas):
        # Binding tools returns the same fake object.
        return self

    def invoke(self, msgs):
        # Count each call.
        self.calls += 1
        # First call: propose the R tool "add" with arguments.
        if self.calls == 1:
            return AIMessage(content="", tool_calls=[{
                "name": "add", "args": {"a": 1, "b": 2},
                "id": "call_add_1", "type": "tool_call"}])
        # Later calls: answer directly.
        return AIMessage(content="The answer is 3.")


# Import our modules (after env vars are set).
import bridge  # noqa: E402
import graph_spec  # noqa: E402
import registry  # noqa: E402
import runtime  # noqa: E402

# ---- Test 1: assistant path (tool via interrupt/resume) -------------------

# Replace the real model class with the fake one inside the runtime module.
runtime.ChatOpenAI = FakeLLM
# Drop any cached compiled graph so it is rebuilt with the fake model.
runtime.reset_runtime_caches()

# Register an R-only tool named "add" with a simple numeric schema.
registry.registry.register_r_tool(
    "add", "add two numbers",
    {"type": "object",
     "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
     "required": ["a", "b"]})

# First assistant run must come back interrupted with the tool request.
r1 = bridge.run_assistant("thread_a1", input_text="what is 1+2?")
assert r1["status"] == "interrupted", r1
assert r1["interrupts"][0]["name"] == "add", r1
assert r1["interrupts"][0]["args"] == {"a": 1, "b": 2}, r1
print("ASSISTANT interrupt OK:", r1["interrupts"])

# Resume with the R-computed result; the run must complete with the answer.
r2 = bridge.run_assistant("thread_a1", resume_value={"results": [{"value": 3}]})
assert r2["status"] == "completed", r2
assert "3" in (r2["content"] or ""), r2
print("ASSISTANT resume OK:", r2["status"], repr(r2["content"]))

# ---- Test 2: graph path (R nodes via interrupt/goto/updates) --------------

# Define a tiny two-node graph spec exactly like the R compiler would send.
spec = graph_spec.validate_graph_spec({
    "graph_id": "demo_graph",
    "state": {"counter": {"type": "number", "reducer": "overwrite"},
              "log": {"type": "list", "reducer": "append"}},
    "nodes": [{"id": "a"}, {"id": "b"}],
    "entry": "a",
    "edges": [{"from": "a", "to": "b"}],
    "defaults": {"a": "b"},
})

# Register the validated spec.
registry.registry.register_graph(spec)
# Make sure the graph is compiled fresh for the test.
runtime.reset_runtime_caches()

# First run: node "a" interrupts with the current state.
g1 = bridge.run_graph("demo_graph", "thread_g1", input_text="go")
assert g1["status"] == "interrupted", g1
assert g1["interrupts"][0]["node"] == "a", g1
assert g1["interrupts"][0]["state"].get("input") == "go", g1
print("GRAPH node a interrupt OK:", g1["interrupts"])

# Resume node a: set counter to 1 and append to the log, goto b.
g2 = bridge.run_graph("demo_graph", "thread_g1", resume_value={
    "reply": {"goto": "b", "updates": {"counter": 1, "log": "step-a"}}})
assert g2["status"] == "interrupted", g2
assert g2["interrupts"][0]["node"] == "b", g2
assert g2["interrupts"][0]["state"]["counter"] == 1, g2
print("GRAPH node b interrupt OK, state:", g2["interrupts"][0]["state"])

# Resume node b: no goto (uses default = end), final update.
g3 = bridge.run_graph("demo_graph", "thread_g1", resume_value={
    "reply": {"goto": None, "updates": {"counter": 2, "log": "step-b"}}})
assert g3["status"] == "completed", g3
assert g3["state"]["counter"] == 2, g3
assert g3["state"]["log"] == ["step-a", "step-b"], g3
print("GRAPH completed OK, final state:", g3["state"])

# ---- Summary ---------------------------------------------------------------
print("BRIDGE SMOKE TEST PASSED")
