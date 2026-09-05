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
# Security: this file contains an API key in plain text. Do not commit it
# to a public repository; if it leaks, rotate the key in the DeepSeek console.

# Load the langgraphr package so we can restart the server afterwards.
library(langgraphr)

# Point the package at the ready-to-use Python venv from this repository.
# (Change this path if your project lives somewhere else.)
options(langgraphr.python = "C:/Users/berry/Desktop/creatingWrapper For LangGraph/langgraphr/inst/server/.venv/Scripts/python.exe")

# Set the model id the assistant path will ask DeepSeek to use.
Sys.setenv(LANGGRAPHR_MODEL = "deepseek-v4-flash")

# Set the API key that authenticates us with DeepSeek.
Sys.setenv(LANGGRAPHR_API_KEY = "REDACTED-ROTATE-THIS-KEY")

# Set the DeepSeek API base URL. Clean value, no backticks, no quotes inside.
Sys.setenv(LANGGRAPHR_BASE_URL = "https://api.deepseek.com")

# Stop any running hidden server so the NEXT start inherits these settings.
lg_stop_server()

# Print the three values back so you can SEE they were set correctly.
cat("MODEL  :", Sys.getenv("LANGGRAPHR_MODEL"), "\n")
cat("BASE   :", Sys.getenv("LANGGRAPHR_BASE_URL"), "\n")
cat("KEY set:", nzchar(Sys.getenv("LANGGRAPHR_API_KEY")), "\n")
