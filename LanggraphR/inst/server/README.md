# langgraphr server bundle

This folder is the **hidden server** shipped inside the R package
(`langgraphr/inst/server`). It is Python only because the LangGraph engine is
Python. End users never write, install, or see it: the R package spawns it as
a background process and speaks HTTP to `127.0.0.1`.

## Files

| File | Role |
|---|---|
| `app.py` | FastAPI entry point (`app:app`); the HTTP contract |
| `bridge.py` | Run orchestration: start/resume assistant and graph runs |
| `runtime.py` | Compiles assistant + developer graphs into real LangGraph graphs |
| `registry.py` | Thread-safe registry of tool schemas and graph specs |
| `graph_spec.py` | Pure validation of the JSON graph spec from the R DSL |
| `tests/bridge_smoke.py` | No-network regression tests for both run paths |
| `requirements.txt` / `pyproject.toml` | Dependency manifests (used by `uv sync`) |

## Run it manually (debugging only)

```powershell
uv sync                                   # one-time
uv run uvicorn app:app --host 127.0.0.1 --port 8123
```

Model settings come from environment variables (see `.env.example`).

## Regression tests

```powershell
uv run python tests/bridge_smoke.py
```

## Design note

R code (node bodies and tools) executes in the R session, never here. When the
graph needs R, it raises a LangGraph interrupt carrying a JSON payload; the R
client answers by resuming the run. All engine pieces are MIT-licensed.
