# 09 — Hiding Python & Error Translation

Goal (P2 + P5): the user writes R, sees R, and never encounters Python.

## 1. What the user never sees
| Item | How it is hidden |
|---|---|
| Python install | `uv` or the bundled venv is resolved/created automatically by `lg_start_server()` |
| Python files | ship inside the package (`inst/server/`); not meant to be opened |
| Server process | spawned invisibly with `processx`; logs go to a temp file |
| Python tracebacks | never forwarded to R (section 3) |
| Python concepts | error messages speak R: "graph", "node", "state field", never `StateGraph` internals |

## 2. Where Python may still be required (honest note)
The machine must be able to run the hidden server, so a Python runtime must
exist *somewhere* on the OS (installed by the user or fetched by `uv`). This is
equivalent to "R needs a JVM for some packages." The user never writes Python.

## 3. Error translation rules (R client)
1. Every server error arrives as `{detail: msg}` with HTTP >= 400.
2. The R client turns it into a `cli` error with a prefixed, human message.
3. Server-side handler maps exceptions:
   - model configuration problems → "Model not configured: set LANGGRAPHR_MODEL
     and LANGGRAPHR_API_KEY (or LANGGRAPHR_BASE_URL)."
   - unknown graph/tool/thread → named 404 message.
   - anything else → "Agent run failed: <short message>", with the full
     technical detail appended to the server log file only.
4. R nodes/tools that raise R errors are caught by the R runtime and reported
   as interrupted-run failures with the R error message (which is R, not Python).

## 4. Assertions (tests that enforce hiding)
- No HTTP error body returned to R contains `Traceback` or `.py` paths.
- `lg_start_server()` never prints a Python command to the user (logs only).
- All public R functions return R objects; none returns raw server JSON
  strings to the console except via documented fields.

## 5. Dev escape hatch (for maintainers only)
`options(langgraphr.debug = TRUE)` prints server stdout lines to the R console
and keeps the server log path in the message. End users never set this.
