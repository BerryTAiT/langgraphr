# deepseek_setup.R - one-line model setup for the langgraphr assistant path.
#
# Using this file removes all copy-paste mistakes: sourcing it sets the
# DeepSeek environment variables programmatically. There are NO backticks
# or quotes to get wrong.
#
# Usage in the R console:
#   source("examples/deepseek_setup.R")
#   lg_stop_server()                # restart the hidden server with new env
#   source("examples/quickstart.R")
#
# Security: the API key is NOT stored in this file. It is loaded from the
# git-ignored agent_example/.env file (or set it via .Renviron). If a key
# ever leaks, rotate it in the DeepSeek console immediately.

# Load the langgraphr package so we can restart the server afterwards.
library(langgraphr)

# Load model credentials from the git-ignored .env file.
# Create it from the template with your own key:
#   LANGGRAPHR_MODEL=deepseek-v4-flash
#   LANGGRAPHR_API_KEY=sk-your-key
#   LANGGRAPHR_BASE_URL=https://api.deepseek.com
dotenv::load_dot_env("agent_example/.env")

# Stop any running hidden server so the NEXT start inherits these settings.
lg_stop_server()

# Print the three values back so you can SEE they were set correctly.
cat("MODEL  :", Sys.getenv("LANGGRAPHR_MODEL"), "\n")
cat("BASE   :", Sys.getenv("LANGGRAPHR_BASE_URL"), "\n")
cat("KEY set:", nzchar(Sys.getenv("LANGGRAPHR_API_KEY")), "\n")
