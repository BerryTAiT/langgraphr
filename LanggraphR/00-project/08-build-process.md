# 08 — Build & Verification Process

## 1. One-time setup (developer machine)
```powershell
# server deps (creates langgraphr/inst/server/.venv via uv)
./scripts/setup_server.ps1

# R package install (requires R >= 4.2)
./scripts/build_r_package.ps1
```

## 2. Code lifecycle (the MD-first rule)
1. Real code lives **first** in `00-project/annotated/**/*.md` as fenced code
   blocks, one block per real file, every line commented in simple English.
2. Each MD declares its target path in an HTML comment:
   `<!-- TARGET: langgraphr/R/client.R -->`
3. `scripts/tools/extract_code.py` parses every annotated MD and writes the
   block content to the target path. Run it after any MD edit:
   ```powershell
   python scripts/tools/extract_code.py
   ```
4. Never hand-edit generated real files; edit the MD and re-extract.

## 3. Verification gates
| Gate | Command / action | Pass = |
|---|---|---|
| Python syntax | `python -m py_compile app.py registry.py runtime.py graph_spec.py bridge.py` (in server dir) | exit 0 |
| Deps resolve | `uv sync` (or `./scripts/setup_server.ps1`) | clean install |
| Server imports | import `app` with env vars set | no exception |
| Bridge + graph smoke | `uv run python tests/bridge_smoke.py` (server dir) | `BRIDGE SMOKE TEST PASSED` and `GRAPH SMOKE TEST PASSED` |
| HTTP contract | boot uvicorn; GET `/health`, POST `/tools/register`, `/graphs/register` | 200s |
| R package | `R CMD check` (on a machine with R) | 0 errors |

## 4. Running the hidden server manually (debug)
```powershell
./scripts/run_server_dev.ps1          # foreground uvicorn on 127.0.0.1:8123
```

## 5. Packaging & distribution (roadmap)
- Binary server bundles per OS (PyInstaller/uv standalone) → M5+.
- R-universe / CRAN publishing with a stub downloader for the bundle → M5+.
- CI: Windows runner doing gates above → M5+.

## 6. This machine's constraints (recorded in HISTORY)
- No R installed → R gates documented, executed later by the user.
- Windows + PowerShell; bash equivalents listed in each script header.
