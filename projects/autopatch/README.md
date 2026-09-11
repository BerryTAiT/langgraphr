# AutoPatch — Enterprise Autonomous Modernization & Patching Engine

An agentic system built entirely with **langgraphr** (R) that audits a code
repository, patches every defective file through a Refactor → Test →
Self-Correct loop, aggregates the results, and parks at a **human review
gate** before writing a PR bundle.

This project is also a stress test of the langgraphr package itself. It
exercised the full-authoring DSL end to end and surfaced (and fixed) a real
package bug. Findings are summarized at the bottom.

```
scanner ──► dispatch ──► dispatch ──► ... ──► gate ──► pr ──► END
              │  (self-cycle: one worker run per file, sequential
              │   map-reduce; fixes aggregate via an append reducer)
              ▼
        worker subgraph (own graph, own thread):
        refactor ⇄ test  (cycle on failure with stderr feedback,
                          give up after max attempts)
```

## Layout

```
autopatch/
├── main.R                 console entry point (CLI flags below)
├── app.R                  Shiny chat UI (stock shinychat look)
├── test_durability.R      crash-recovery probe (re-invoke on crashed thread)
├── test_app_worker.R      background-worker E2E probe (app's callr path)
├── R/
│   ├── env.R              .env loading for LLM credentials
│   ├── defects.R          defect scanner (hardcoded secrets, eval/parse,
│   │                      .Internal, 1:n, = assignment, T/F, no seq_len...)
│   ├── fixer.R            deterministic rule-based fixes
│   ├── llm_refactor.R     LLM refactoring + output validation, with
│   │                      stderr feedback from the previous failed attempt
│   ├── test_runner.R      runs the file's tests on the candidate in an
│   │                      Rscript subprocess (args, not env vars: Windows)
│   ├── graph.R            the two graphs (worker + orchestrator)
│   └── chat.R             chat brain (persona + 7 tools) shared by console
│                          AND web UI; ap_chat_turn() is the self-contained
│                          background-worker turn
├── sample_repo/           4 deliberately defective R files + tests/
└── patches/PR_<stamp>/    output: patched R/, PR_DESCRIPTION.md, report.md
```

## Usage

**Web UI (shinychat, stock look):**

```r
shiny::runApp("projects/autopatch/app.R")
```

Plain shinychat: the default feed + input box, no custom theme or sidebar.
Paste R code or ask about the repo; the agent reviews it (rendered markdown +
colored code blocks). Every turn runs in a background process so the UI never
freezes. Conversation memory survives restarts (`chat_thread_id.txt` +
`autopatch.db`). A single "New conversation" button clears the thread.

**Chat mode (console) — bring your code, ask questions:**

```r
# in an interactive R session (RStudio: open main.R, press Source)
source("projects/autopatch/main.R")
```

The agent waits for your input, then reviews what you give it. Type `code`
to paste multi-line R code (finish with a line containing only `###`);
it lists concrete problems with line numbers and suggests fixes. It never
asks y/N — approval belongs to the pipeline below. `clear` resets the
conversation; `quit` leaves. (Chat needs an interactive session: under
Rscript on Windows, R's stdin is wired to the script file itself, so
console input is unreachable — you'll get guidance instead of a hang.)

**Patch pipeline — scan → patch → test → human gate → PR:**

```bash
Rscript main.R --run                    # y/N gate at the end, after diffs
Rscript main.R --run --yes              # LLM first, rules fallback, auto-approve
Rscript main.R --run --no-llm --yes     # deterministic: rules only
Rscript main.R --run --no-llm --stress --yes   # strict tests → retry cycles
Rscript main.R --run --no-llm --park D:/decision.txt  # park until file appears
Rscript main.R --run --repo C:/path --no-llm --yes    # patch another repo
Rscript main.R --resume <thread_id>     # crash-recovery probe (documents a gap)
```

Workers run each candidate against `sample_repo/tests/test_<file>.R` in a
subprocess; a patch is only accepted when its tests pass (or attempts are
exhausted, verdict `failed`).

## LangGraph features exercised (all verified 2026-09-10)

| Feature | langgraphR construct | Where |
|---|---|---|
| State reducers (`operator.add`) | `list(type="list", reducer="append")` | orchestrator `fixes` channel aggregates one record per worker run |
| Map-reduce fan-out | `dispatch` node self-cycle (`goto = "dispatch"`) + append reducer | sequential map-reduce over the scanner's queue (parallel `Send` is a known package gap) |
| Subgraphs | two separately compiled graphs; orchestrator node invokes the worker graph nested | `dispatch` → `worker$invoke()` inside a node |
| Dynamic control flow (`Command`) | node returns `list(updates=..., goto=...)` | worker `test` routes to `refactor` or `__end__`; orchestrator routes everywhere |
| Human-in-the-loop | the run simply stops at the gate node interrupt and waits for the resume | gate prints diffs, reads y/N (or `--yes`, or `--park` file) |
| Thread persistence | `lg_use_sqlite()` → SqliteSaver checkpoints in `autopatch.db` | every node transition is checkpointed |
| Cyclic retry loops | `refactor ⇄ test` edge cycle with `error_log` feedback | worker retries with LLM (using stderr), falls back to rules, gives up after max attempts |

## Verified test matrix

| Scenario | Command | Result |
|---|---|---|
| Happy path, rules only | `--no-llm --yes` | 4/4 files patched, attempts=1, PR bundle + report written |
| Retry cycle (cyclic loop) | `--no-llm --stress --yes` | attempt 1 fails stress check → error feedback → attempt 2 passes (attempts=2) |
| Gate rejection | `--no-llm`, answer `n` | "REJECTED by reviewer — 4 file(s) fixed but no PR created", no bundle |
| Crash + durability | park at gate → kill R **and** server → re-invoke on same thread | gate shows 8 records (4 from the crashed run + 4 new): the `fixes` append channel survived the full-stack crash via SQLite checkpoints |
| Resume after restart | `--resume <thread_id>` | **GAP**: 404 (see below) |

## Package findings

### Fixed during this project

**Static edges fan out alongside `Command(goto)`** —
`runtime.py:_build_graph_from_spec` used to add static `add_edge` calls for
every declared default edge. With LangGraph 1.2.11, a node that returns
`Command(goto=X)` while a static edge points at Y creates **two parallel
tasks** (X and Y) → two simultaneous node interrupts → the R client services
the first, and the next resume 500s with *"you must specify the interrupt id
when resuming"*. Any graph whose dynamic `goto` disagrees with its declared
default edge (self-cycles, conditional branches) hit this. Fix: stop adding
static per-node edges; routing is fully Command-driven since every node
wrapper returns a `Command`. (Fixed in the annotated source + regenerated +
reinstalled; repro was a 4-node graph with a self-cycling node.)

### Known gaps (documented, not fixed)

1. **Parallel `Send` fan-out** — roadmap item. AutoPatch works around it with
   a sequential dispatch self-cycle (correct, just not concurrent).
2. **Server restart loses thread ownership** — `_thread_kind` in `app.py` is
   an in-memory map. After a crash+restart, `/threads/<id>/resume` returns
   404 even though the thread's checkpoints are durable in SQLite. Re-invoking
   the graph on the same thread works (checkpoints load; append channels
   accumulate), but a true "resume the parked run" API needs thread kind
   persisted alongside the checkpointer.
3. **Hard-killing R orphans the server** — `processx` supervision cannot
   clean up on `TerminateProcess`; the Python sidecar survives a hard kill of
   the R parent (it does die on normal R exit).
4. **Node errors end the run silently** — if an R node function throws, the
   error propagates out of `$invoke()` (loud), but if a caller swallows it
   and resumes with an empty reply, the run follows the default edge as if
   nothing happened. Node bodies that must not die should tryCatch
   internally (AutoPatch's dispatch does this around worker runs).

### langgraphR authoring sharp edge (bit us once)

`lg_add_edge()` / `lg_add_node()` return a **new** builder — always
reassign: `b <- lg_add_edge(b, ...)`. Node *functions* still register
without reassignment (they live in a shared environment), so a forgotten
reassignment silently produces a graph with working functions but **missing
edges/defaults** — the run just ends early instead of erroring.
