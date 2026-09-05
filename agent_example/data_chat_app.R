# data_chat_app.R - "chat with your data" Shiny app via querychat.
#
# A polished one-stop app: chat sidebar on the left, live data table on the
# right, and the generated SQL shown for transparency. Under the hood it is
# shinychat + ellmer + DuckDB.
#
# Run in the R console:
#   source("agent_example/data_chat_app.R")

# Credentials for the LLM (kept out of the script).
dotenv::load_dot_env("agent_example/.env")

library(querychat)

# The data people will chat with (swap in any data frame).
products_df <- data.frame(
  product = c("Aurora", "Nimbus", "Ember", "Cobalt", "Drift"),
  revenue = c(120.5, 340.2, 95.0, 210.8, 480.1)
)

# A DeepSeek-backed ellmer client for querychat to use.
client <- ellmer::chat_openai(
  model    = Sys.getenv("LANGGRAPHR_MODEL", unset = "gpt-4o-mini"),
  api_key  = Sys.getenv("LANGGRAPHR_API_KEY"),
  base_url = "https://api.deepseek.com"
)

# Launch the polished querychat Shiny app.
querychat_app(products_df, client = client)
