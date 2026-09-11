# r_chatbot - a pure-R console chatbot with persistent memory

A simple conversational chatbot built entirely in R with the local
**langgraphr** package. You type in the R console; the bot answers with
full memory of the conversation. No Shiny, no other languages, no manual
server management.

## Install

Requires R >= 4.1.

```r
# 1. Install langgraphr from the local package folder:
remotes::install_local("LanggraphR", upgrade = "never")
#    (run from the repository root; the folder contains DESCRIPTION)

# 2. Install the two runtime dependencies used by this app:
install.packages(c("dotenv", "R6", "cli"))

# 3. Add your model credentials to projects/r_chatbot/.env
#    (see .Renviron.example for the variable names)
```

That is all - the background server that runs the graph engine is
started automatically by `lg_connect()` and needs no manual setup.

## Run

Console version:

```r
source("projects/r_chatbot/main.R")
```

**Shiny chat UI** (recommended - message bubbles, never freezes while the
bot thinks, agent calls run in a background process):

```r
shiny::runApp("projects/r_chatbot/app.R")
```

Both front ends share the same brain (`R/graph.R`, `R/tools.R`): same
personality, same tools, same memory.

Commands while chatting:

| Input        | Effect                                          |
|--------------|-------------------------------------------------|
| anything else | sent to the bot as a chat message              |
| `clear`      | reset the conversation memory, re-seed persona  |
| `quit` / `exit` | end the chat gracefully                      |

## Configuration

`.env` (never commit it; see `.Renviron.example`):

```
LANGGRAPHR_MODEL=deepseek-v4-flash
LANGGRAPHR_API_KEY=sk-...
LANGGRAPHR_BASE_URL=https://api.deepseek.com
```

For durability between R sessions, set `USE_PERSISTENT_MEMORY <- TRUE` in
`main.R` (or uncomment `LANGGRAPHR_DB` in `.env`). The conversation is
then checkpointed to a SQLite file and reloaded when the server restarts.

## How state flows through langgraphr

```
R session                 hidden local server            graph engine
-----------               -------------------            ------------
agent$invoke("hi")  ---->  POST /threads/<id>/runs  ---> runs the assistant
   |                                                        graph on the
   |                                                        thread's state
   |                                                        (full message
   |                                                        history)
   |                      tool needed? the run is PAUSED and an interrupt
   |  <--- interrupted --- comes back over HTTP
   |
your R tool runs locally
(e.g. session_info_tool)
   |
   |  --- resume -------->  POST /threads/<id>/resume -> run continues
   |                                                        with the tool
   |                                                        result
   |  <--- completed ------ final reply + updated state
reply shown in console
```

- **Thread memory**: every conversation is keyed by `thread_id`. The same
  id keeps the history across turns (and, with SQLite, across sessions);
  `agent$reset()` swaps in a fresh id, which is exactly what "clear" does.
- **Tools**: registered R functions execute in *your* R session with your
  data, packages and environment - the engine only decides *when* to call
  them.
- **Summarize step**: every 10 user messages the bot compresses the
  history: it summarizes the current thread, `reset()` starts a fresh
  one, and the summary is carried in as the first message.

## Extending: adding a tool

Two small edits in `R/tools.R` only:

```r
# 1. the function
current_time_tool <- function() format(Sys.time(), "%Y-%m-%d %H:%M")

# 2. one registration line inside register_tools()
agent$add_tool(current_time_tool,
               description = "Return the current local date and time.")
```

The model decides on its own when to call it.

## Example console session

```
=============================================
  r_chatbot - a console chatbot (langgraphr)
=============================================
Type a message and press Enter to chat.
Commands:  clear = reset memory | quit/exit = leave

You: Hi! My name is Berry and I love R.
Ada: ... thinking
Ada: Hi Berry! Nice to meet you - an R fan after my own heart.
     What are you working on today?

You: Remember: my favorite number is 42.
Ada: ... thinking
Ada: Got it - your favorite number is 42. I'll keep that in mind, Berry.

You: What did I say my favorite number was?
Ada: ... thinking
Ada: You said your favorite number is 42.

You: clear
Ada: (memory cleared - fresh conversation)

You: What's my name?
Ada: ... thinking
Ada: I don't know your name yet - we're starting fresh! What should
     I call you?

You: what's my R environment?
Ada: ... thinking
Ada: Here's your R environment:
     - R version: R version 4.6.1 (2026-06-24 ucrt)
     - Platform: x86_64-w64-mingw32
     - Working directory: C:/Users/berry/Desktop/creatingWrapper For LangGraph
     - Loaded packages: cli, compiler, dotenv, grDevices, jsonlite,
       langgraphr, methods, R6, stats, utils

You: quit
Ada: Goodbye! Chat again any time.
```

(The 3 turns before `clear` prove the bot remembers; the "What's my
name?" turn right after `clear` proves the memory reset worked. The
environment answer came from `session_info_tool()`, an R function that
ran locally when the model asked for it.)
