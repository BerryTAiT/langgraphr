# my_agent.R - a small AI agent in R using the langgraphr package.
#
# The agent has two R tools: one that computes simple stats, and one that
# formats a currency value. The LLM decides when to call them.

# ---- Model credentials (kept out of the script) ------------------------------
# Credentials live in agent_example/.env (never commit this file).
# Install once with: install.packages("dotenv")
dotenv::load_dot_env("agent_example/.env")
stopifnot(nzchar(Sys.getenv("LANGGRAPHR_API_KEY")))

library(langgraphr)

# ---- 1. R functions that become agent tools ---------------------------------

# Summarise a numeric vector: count, mean, min, max.
summarize_numbers <- function(numbers) {
  numbers <- as.numeric(numbers)
  list(
    n     = length(numbers),
    mean  = mean(numbers),
    min   = min(numbers),
    max   = max(numbers)
  )
}

# Format a numeric value as US dollars.
format_usd <- function(value) {
  sprintf("$%.2f", as.numeric(value))
}

# ---- 2. Connect to the hidden server ----------------------------------------
agent <- lg_connect()

# Register the tools with descriptions the model uses to pick them.
agent$add_tool(summarize_numbers,
               description = "Compute n, mean, min and max of a numeric vector")
agent$add_tool(format_usd,
               description = "Format a numeric value as US dollars, e.g. 12.5 -> $12.50")

# ---- 3. Ask the agent something that needs both tools -------------------------
res <- agent$invoke(paste0(
  "Here are last week's daily sales figures: 120.5, 340.2, 95, 210.8, 480.1. ",
  "Summarise them (count, mean, min, max) and express the mean in US dollars."
))

cat("Assistant:", res$content, "\n")

# ---- 4. Follow-up: the same thread remembers the previous exchange -------------
res2 <- agent$invoke("Which was larger: the max or the mean you just computed?")
cat("Assistant:", res2$content, "\n")
