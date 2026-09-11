# langgraphr/inst/server/graph_spec.py

<!-- TARGET: langgraphr/inst/server/graph_spec.py -->

> Pure validation/normalisation of the JSON graph spec sent by the R compiler.
> No side effects; raises ValueError with clear messages.

```py
# graph_spec.py - validate and normalise a graph spec (pure functions).
#
# The R compiler sends a spec that looks like this (JSON):
# {
#   "graph_id": "demo",
#   "state":  {"counter": {"type": "number", "reducer": "overwrite"}},
#   "nodes":  [{"id": "inc"}],
#   "entry":  "inc",
#   "edges":  [{"from": "inc", "to": "inc"}],
#   "defaults": {"inc": "inc"}
# }
# This module checks that spec and returns a clean copy the runtime can use.

# Types the state fields may declare.
_ALLOWED_TYPES = {"str", "number", "boolean", "list", "any"}

# Reducers we know how to implement server-side.
_ALLOWED_REDUCERS = {"overwrite", "append"}


def validate_graph_spec(spec: dict) -> dict:
    """Validate a raw spec dict; return a normalised copy.

    Raises ValueError (with an English, R-friendly message) on the first
    problem found, so the HTTP layer can turn it into a clean error.
    """
    # The spec must be a dict at all.
    if not isinstance(spec, dict):
        raise ValueError("graph spec must be a JSON object")

    # graph_id: required non-empty string.
    graph_id = spec.get("graph_id")
    if not isinstance(graph_id, str) or not graph_id.strip():
        raise ValueError("graph spec is missing a 'graph_id' string")

    # state: optional dict of field specs.
    state = spec.get("state") or {}
    # State must be a dict of field-name -> field-spec.
    if not isinstance(state, dict):
        raise ValueError("'state' must be an object of field specs")
    # Remember the normalised state we build.
    normal_state = {}
    # Loop over every declared state field.
    for fname, fspec in state.items():
        # Each field spec must be a dict.
        if not isinstance(fspec, dict):
            raise ValueError(f"state field '{fname}' must be an object")
        # Read the optional type; default to 'any'.
        ftype = fspec.get("type", "any")
        # Reject unknown types so R and Python agree on serialisation.
        if ftype not in _ALLOWED_TYPES:
            raise ValueError(
                f"state field '{fname}' has unknown type '{ftype}'")
        # Read the optional reducer; default to overwrite.
        reducer = fspec.get("reducer", "overwrite")
        # Reject reducers we have not implemented.
        if reducer not in _ALLOWED_REDUCERS:
            raise ValueError(
                f"state field '{fname}' has unknown reducer '{reducer}'")
        # Read the optional human description.
        description = fspec.get("description", "")
        # Keep only the fields we understand in the normalised spec.
        normal_state[fname] = {
            "type": ftype,
            "reducer": reducer,
            "description": description,
        }

    # nodes: at least one node, each with a unique non-empty string id.
    nodes = spec.get("nodes") or []
    # Node storage must be a list.
    if not isinstance(nodes, list) or not nodes:
        raise ValueError("graph spec needs at least one node in 'nodes'")
    # This list will hold the normalised node descriptors.
    normal_nodes = []
    # Remember every node id so we can detect duplicates and bad edges.
    node_ids = set()
    # Loop over every node descriptor.
    for node in nodes:
        # Each node must be a dict with an id.
        if not isinstance(node, dict) or not isinstance(node.get("id"), str):
            raise ValueError("each node must be an object with an 'id' string")
        # Read the node id.
        nid = node["id"]
        # Reject empty ids.
        if not nid.strip():
            raise ValueError("node ids must not be empty")
        # Reject duplicate ids.
        if nid in node_ids:
            raise ValueError(f"duplicate node id '{nid}'")
        # Remember this id for later checks.
        node_ids.add(nid)
        # Read the optional description.
        description = node.get("description", "")
        # Append the normalised node descriptor.
        normal_nodes.append({"id": nid, "description": description})

    # entry: must name an existing node.
    entry = spec.get("entry") or normal_nodes[0]["id"]
    # Reject an entry node that does not exist.
    if entry not in node_ids:
        raise ValueError(f"entry node '{entry}' does not exist")

    # edges: optional list of {from, to} referencing existing nodes.
    edges = spec.get("edges") or []
    # Edge storage must be a list.
    if not isinstance(edges, list):
        raise ValueError("'edges' must be a list")
    # This list holds the normalised edges.
    normal_edges = []
    # Loop over every declared edge.
    for edge in edges:
        # Each edge must be a dict with from/to strings.
        if not isinstance(edge, dict):
            raise ValueError("each edge must be an object")
        # Read the two endpoints.
        frm = edge.get("from")
        to = edge.get("to")
        # Both endpoints must exist.
        if frm not in node_ids:
            raise ValueError(f"edge references unknown node '{frm}'")
        if to not in node_ids:
            raise ValueError(f"edge references unknown node '{to}'")
        # Keep the normalised edge.
        normal_edges.append({"from": frm, "to": to})

    # defaults: optional map node -> default next node (must exist).
    defaults = spec.get("defaults") or {}
    # Defaults must be a dict.
    if not isinstance(defaults, dict):
        raise ValueError("'defaults' must be an object")
    # This dict holds the normalised defaults.
    normal_defaults = {}
    # Loop over every declared default.
    for nid, to in defaults.items():
        # The key must be a real node.
        if nid not in node_ids:
            raise ValueError(f"default for unknown node '{nid}'")
        # The value must be a real node or the end marker.
        if to not in node_ids and to != "__end__":
            raise ValueError(
                f"default of node '{nid}' targets unknown node '{to}'")
        # Remember the default.
        normal_defaults[nid] = to

    # Return one clean, validated spec the runtime can trust.
    return {
        "graph_id": graph_id.strip(),
        "state": normal_state,
        "nodes": normal_nodes,
        "entry": entry,
        "edges": normal_edges,
        "defaults": normal_defaults,
    }
```
