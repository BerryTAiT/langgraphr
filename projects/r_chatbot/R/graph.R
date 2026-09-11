# graph.R - builds the chatbot's "brain" with the langgraphr package.
#
# The chatbot uses the ASSISTANT path: lg_connect() returns a ready-made
# conversational agent - a single-node graph, no branching to design. The
# full message history lives in the graph state on the server, keyed by the
# agent's thread_id; langgraphr manages that state automatically, so this
# file only decides personality, tools and memory policy.

# PERSONALITY - the bot's character. Edit this string to change who the
# bot is; it is seeded as the very first message of every conversation.
PERSONALITY <- paste0(
  "You are Ada, a warm and concise assistant living in an R console. ",
  "Prefer short answers, and show small runnable R snippets when code ",
  "helps. Stay in character at all times."
)

# SUMMARY_EVERY - the summarize step fires after this many user messages,
# compressing the history so the context the model sees stays short.
SUMMARY_EVERY <- 10L

# new_chatbot() returns a chat-ready agent.
#
# @param durable  TRUE = conversations survive between R sessions via
#   SQLite; FALSE = memory lives only while the server runs (in-process).
# @param db_path  Where the SQLite file lives when durable = TRUE.
new_chatbot <- function(durable = FALSE, db_path = NULL) {
  # Durable memory: lg_use_sqlite() points the server at a SQLite file so
  # every thread's history is written to disk and reloaded on the next
  # server start. It must run BEFORE lg_connect(), because the server only
  # reads the setting once at boot. With durable = FALSE this is skipped
  # and memory resets whenever the server restarts.
  if (isTRUE(durable)) {
    if (is.null(db_path)) db_path <- "chatbot_memory.sqlite"
    lg_use_sqlite(db_path)
  }

  # lg_connect() starts the hidden server (if not already running) and
  # returns an LgAgent. Its thread_id is the memory key: every invoke()
  # continues the conversation stored under that id, and reset() swaps in
  # a fresh id to start over. A fresh conversation is seeded below.
  agent <- lg_connect()

  # Register the R tools the model may call (see tools.R).
  agent <- register_tools(agent)

  # Seed the personality: send it as the first message of the fresh thread
  # so the whole history (including the instruction) stays in state.
  seed_agent(agent)

  # Hand the ready-to-chat agent back.
  agent
}

# seed_agent() injects the personality (and an optional carry-over summary)
# as the first message of the agent's current thread.
seed_agent <- function(agent, summary = NULL) {
  parts <- c(paste0("System note: ", PERSONALITY))
  # When a summary is carried over, keep it right after the personality.
  if (!is.null(summary) && nzchar(summary)) {
    parts <- c(parts, paste0("Summary of our earlier conversation: ",
                             summary))
  }
  parts <- c(parts, "Acknowledge by replying with exactly: Ready.")
  # The reply to the seed is not shown to the user; it only matters that
  # the instruction now sits at the top of the remembered history.
  invisible(agent$invoke(paste(parts, collapse = "\n")))
}

# maybe_summarize() is the optional "summarize" step: after every
# SUMMARY_EVERY user messages it compresses the conversation. The
# assistant path has a single server-side node, so the compression runs
# here in R: ask the bot (which still remembers everything on this
# thread) to summarize, then reset to a fresh thread whose first message
# carries the summary forward. Context stays short; key facts survive.
#
# @return TRUE when a compression happened, FALSE otherwise.
maybe_summarize <- function(agent, message_count) {
  # Only fire exactly on multiples of the threshold.
  if (message_count <= 0L || message_count %% SUMMARY_EVERY != 0L) {
    return(FALSE)
  }
  # Same thread = full history is still in state for this one request.
  res <- agent$invoke(paste0(
    "Summarize our conversation so far in at most 3 sentences. ",
    "Keep names, numbers and any open questions."))
  summary <- if (is.null(res$content)) "" else res$content
  # reset() moves the agent to a brand-new thread id: the old history is
  # dropped and only the summary travels forward via the seed message.
  agent$reset()
  seed_agent(agent, summary = summary)
  TRUE
}

# chat_turn() - one full conversation turn, self-contained so it can run
# in a BACKGROUND R process (that is how the Shiny front end, app.R, uses
# it: the app stays responsive while the model works). It reconnects to
# the SAME thread (memory is keyed by thread_id and lives on the server),
# registers the tools passed in, seeds the personality on a fresh thread,
# applies the summarize step, and returns the reply.
#
# Everything it needs arrives as arguments, so nothing is shared state:
# @param msg          the user's message
# @param thread_id    which conversation to continue
# @param turn_count   how many user messages this thread has had (drives
#                     the summarize step)
# @param personality  the personality text (PERSONALITY from above)
# @param seed         personality seed text when the thread is fresh,
#                     NULL when it is already seeded
# @param tools        list of list(fn, description) from tool_registry()
# @param summary_every  the summarize threshold (SUMMARY_EVERY)
# @param env_path     where the .env file lives (credentials)
# @param durable/db_path  SQLite memory settings, as in new_chatbot()
chat_turn <- function(msg, thread_id, turn_count, personality,
                      seed = NULL, tools = list(), summary_every = 10L,
                      env_path = NULL, durable = FALSE, db_path = NULL) {
  # Standalone environment: load credentials and memory settings exactly
  # the way new_chatbot() does in the main session.
  library(langgraphr)
  if (!is.null(env_path) && file.exists(env_path)) {
    try(dotenv::load_dot_env(env_path), silent = TRUE)
  }
  if (isTRUE(durable)) {
    if (is.null(db_path)) db_path <- "chatbot_memory.sqlite"
    lg_use_sqlite(db_path)
  }
  # Reconnect to the SAME thread: the server restores this conversation.
  agent <- lg_connect(thread_id = thread_id)
  # Register the tools passed in (plain R functions + descriptions).
  for (t in tools) agent$add_tool(t$fn, description = t$description)
  # Fresh thread: seed the personality first (same idea as seed_agent()).
  if (!is.null(seed) && nzchar(seed)) {
    invisible(agent$invoke(seed))
  }
  # The user's actual message.
  res <- agent$invoke(msg)
  # Summarize step: same policy as maybe_summarize() in the console app.
  note <- NULL
  if (turn_count > 0L && turn_count %% summary_every == 0L) {
    s <- agent$invoke(paste0(
      "Summarize our conversation so far in at most 3 sentences. ",
      "Keep names, numbers and any open questions."))
    agent$reset()
    invisible(agent$invoke(paste0(
      "System note: ", personality,
      "\nSummary of our earlier conversation: ", s$content,
      "\nAcknowledge by replying with exactly: Ready.")))
    note <- paste0("(history compressed after ", summary_every,
                   " messages)")
  }
  # Reply, the compression note, and the thread id (a compression moves
  # the conversation to a fresh one - the front end must track it).
  list(content = if (is.null(res$content)) "(no reply)" else res$content,
       note = note,
       thread_id = agent$thread_id)
}

# clear_history() implements the "clear" command: forget everything and
# start over (no summary carried across - "clear" means clear).
#
# @return The agent, now on a fresh thread with the personality re-seeded.
clear_history <- function(agent) {
  # New thread id = the server no longer associates this agent with the
  # old conversation.
  agent$reset()
  # Re-seed the personality on the new thread.
  seed_agent(agent)
  # Return the agent for convenience.
  agent
}
