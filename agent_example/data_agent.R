# data_agent.R - a langgraphr agent that can chat with data via SQL.
#
# The same idea as querychat (natural language -> SQL -> table) but inside
# the langgraphr assistant: querying the data is just one of the agent's
# R tools, executed with DuckDB in the user's own session.
#
# Run in the R console:
#   source("agent_example/data_agent.R")

# Credentials for the LLM (kept out of the script).
dotenv::load_dot_env("agent_example/.env")

library(langgraphr)
library(duckdb)

# The data the agent will query (swap in any data frame).
products_df <- data.frame(
  product = c("Aurora", "Nimbus", "Ember", "Cobalt", "Drift"),
  revenue = c(120.5, 340.2, 95.0, 210.8, 480.1)
)

# Register the data frame as an in-memory DuckDB table.
con <- DBI::dbConnect(duckdb::duckdb())
# Turn off DuckDB's progress bars: they add console noise during agent runs.
try(DBI::dbExecute(con, "SET enable_progress_bar = false"), silent = TRUE)
DBI::dbWriteTable(con, "products", products_df)

# Tool 1: run read-only SQL against the data and return rows as text.
query_data <- function(sql) {
  rows <- DBI::dbGetQuery(con, sql)
  if (nrow(rows) == 0) return("No rows returned.")
  # Compact text rendering so the model can read the result easily.
  paste(utils::capture.output(print(rows, row.names = FALSE)),
        collapse = "\n")
}

# Tool 2: describe the table so the model learns the column names.
describe_table <- function() {
  paste(utils::capture.output(print(products_df, row.names = FALSE)),
        collapse = "\n")
}

# Connect to the hidden server.
agent <- langgraphr::lg_connect()

# Register the tools with model guidance.
agent$add_tool(describe_table,
               description = paste0(
                 "Show the products table (columns: product, revenue) ",
                 "so you can learn its schema before writing SQL"))
agent$add_tool(query_data,
               description = paste0(
                 "Run a read-only SELECT query on table 'products' with ",
                 "DuckDB SQL. Returns the result rows as text."))

# Ask the agent a data question - it should call the tools, not guess.
res <- agent$invoke(paste0(
  "Which product earned more than $200 in revenue? First look at the ",
  "table schema, then query the data, then tell me the answer and the ",
  "total revenue of those products."
))
cat("Assistant:", res$content, "\n")
