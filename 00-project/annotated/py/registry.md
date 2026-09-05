# langgraphr/inst/server/registry.py

<!-- TARGET: langgraphr/inst/server/registry.py -->

> Thread-safe registry holding: (a) tool schemas, (b) registered graph specs.
> Tools split into python-local callables and R-only schemas.

```py
# registry.py - process-wide registry of tools and graph specs.
#
# The R client registers R functions as tools (schema only, no callable)
# and registers graph specs produced by the R DSL. The runtime reads this
# registry to bind tools onto models and to compile graphs on demand.

# Threading lock keeps the registry safe when several R sessions hit the
# server at the same time (e.g. parallel tests or Shiny apps).
import threading


class Registry:
    """Holds tool schemas, python tool callables and graph specs."""

    def __init__(self) -> None:
        # A lock protects every mutation below.
        self._lock = threading.Lock()
        # Map: tool name -> full OpenAI tool schema (dict).
        self._schemas: dict[str, dict] = {}
        # Map: tool name -> python callable for server-local tools.
        self._python: dict[str, callable] = {}
        # Map: graph id -> validated graph spec (dict).
        self._graphs: dict[str, dict] = {}

    # ---- tool registration ---------------------------------------------
    def register_r_tool(self, name: str, description: str,
                        parameters: dict) -> bool:
        """Register an R-only tool: schema known, callable lives in R."""
        # Build the OpenAI-style schema for this tool.
        schema = {
            "type": "function",
            "function": {
                "name": name,
                "description": description or "",
                # Default to an empty parameter object when none given.
                "parameters": parameters or {
                    "type": "object", "properties": {}},
            },
        }
        # Store the schema under the lock.
        with self._lock:
            self._schemas[name] = schema
        # Report success.
        return True

    def register_python_tool(self, fn: callable, name: str | None = None,
                             description: str | None = None) -> bool:
        """Register a python-local tool (future bundled server tools)."""
        # Default the tool name to the python function name.
        if name is None:
            name = fn.__name__
        # Default the description to the function docstring.
        if description is None:
            description = (fn.__doc__ or "").strip()
        # Python tools get a generic parameters object for now.
        params = {"type": "object", "properties": {}}
        # Store both the callable and its schema under the lock.
        with self._lock:
            self._python[name] = fn
            self._schemas[name] = {
                "type": "function",
                "function": {"name": name,
                             "description": description,
                             "parameters": params},
            }
        # Report success.
        return True

    # ---- tool queries --------------------------------------------------
    def schemas(self) -> list[dict]:
        """Return copies of every tool schema (for model binding)."""
        with self._lock:
            return [dict(v) for v in self._schemas.values()]

    def tool_names(self) -> list[str]:
        """Return all registered tool names."""
        with self._lock:
            return list(self._schemas.keys())

    def is_r_tool(self, name: str) -> bool:
        """True when a tool is R-only (no python callable here)."""
        with self._lock:
            return name in self._schemas and name not in self._python

    def python_names(self) -> set[str]:
        """Names of python-local tools."""
        with self._lock:
            return set(self._python.keys())

    def call_python(self, name: str, args: dict):
        """Invoke a python-local tool with its decoded arguments."""
        # Look up the callable.
        fn = self._python.get(name)
        # Raise a clear error for unknown python tools.
        if fn is None:
            raise KeyError(f"unknown python tool: {name}")
        # Call with arguments when present, otherwise with none.
        if args:
            return fn(**args)
        return fn()

    def drop_tool(self, name: str) -> bool:
        """Remove a tool (python and schema entry)."""
        with self._lock:
            self._python.pop(name, None)
            return self._schemas.pop(name, None) is not None

    # ---- graph registration --------------------------------------------
    def register_graph(self, spec: dict) -> bool:
        """Register (or replace) a graph spec under its graph_id.

        Re-registering an existing id overwrites the old spec. This makes
        development iteration painless: editing R code and re-running an
        example updates the graph instead of failing with a conflict.
        """
        # Read the graph id out of the spec.
        graph_id = spec["graph_id"]
        # Store the spec under the lock (replaces any previous spec).
        with self._lock:
            self._graphs[graph_id] = spec
        # Report success.
        return True

    def graph_ids(self) -> list[str]:
        """List every registered graph id."""
        with self._lock:
            return list(self._graphs.keys())

    def graph_spec(self, graph_id: str) -> dict | None:
        """Return the spec for one graph (or None when unknown)."""
        with self._lock:
            return self._graphs.get(graph_id)


# A single process-wide registry instance is imported everywhere.
registry = Registry()
```
