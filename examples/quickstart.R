# quickstart.R - the quick path: an assistant whose tools are R functions.
#
# Before running:
#   1. scripts/setup_server.ps1            (one-time server dependency install)
#   2. install the package from R:
#        remotes::install_local("langgraphr")
#   3. configure a model (the assistant path needs one):
#        Sys.setenv(LANGGRAPHR_MODEL   = "gpt-4o-mini")
#        Sys.setenv(LANGGRAPHR_API_KEY = "<your key>")   # or OPENAI_API_KEY
#      (the graph path in multi_agent.R needs NO model at all)
# ---------------------------------------------------------------------------

# Load the langgraphr package.
library(langgraphr)

# --- 1. an ordinary R function that will become an agent tool --------------
# This tool ranks a data frame of products by revenue and keeps the top n.
top_products <- function(products, n = 3) {
  # Sort the products by revenue in decreasing order.
  sorted <- products[order(products$revenue, decreasing = TRUE), , drop = FALSE]
  # Keep only the first n rows (the best sellers).
  head(sorted, n)
}

# A second tool that summarises the whole week's revenue.
weekly_report <- function(products) {
  # Add up every product's revenue.
  total <- sum(products$revenue)
  # Return a small list of facts about this week's sales.
  list(total = total, products = nrow(products),
       message = sprintf("Total revenue this week: $%.2f", total))
}

# --- 2. connect: this starts the hidden server on first use ----------------
# lg_connect() also generates a fresh thread id for this conversation.
agent <- lg_connect()

# Register the first R function as an agent tool with guidance for the model.
# We declare the parameter schemas by hand: "products" is an ARRAY of objects
# (a data frame travels as JSON rows), and "n" is an optional number. This
# matters because the model validates its calls against these schemas.
agent$add_tool(
  top_products,
  description = "Return the top-N products by revenue from a product data frame",
  parameters = list(
    type = "object",
    properties = list(
      products = list(type = "array", items = list(type = "object"),
                      description = "Each product with its revenue"),
      n = list(type = "number",
               description = "How many top products to keep")
    ),
    required = list("products")
  )
)

# Register the second R function as another agent tool, with its schema too.
agent$add_tool(
  weekly_report,
  description = "Summarise weekly product revenue totals",
  parameters = list(
    type = "object",
    properties = list(
      products = list(type = "array", items = list(type = "object"),
                      description = "Each product with its revenue")
    ),
    required = list("products")
  )
)

# --- 3. give the agent some data and ask it a question ----------------------
# Build a small example data frame of products and revenue.
products_df <- data.frame(
  product = c("Aurora", "Nimbus", "Ember", "Cobalt", "Drift"),
  revenue = c(120.5, 340.2, 95.0, 210.8, 480.1)
)

# Serialise the data frame to JSON so the agent can "see" it as text.
products_json <- jsonlite::toJSON(products_df, auto_unbox = TRUE)

# Ask the assistant to summarise the week and name the top 3 products.
res <- agent$invoke(paste0(
  "Here are this week's product sales: ", products_json,
  ". Summarise the week and tell me the top 3 products."
))

# Print whatever the assistant answered.
cat("Assistant:", res$content, "\n")

# --- 4. memory: the same thread continues the conversation ------------------
# Because we reuse the same agent (same thread id), the assistant remembers
# the previous exchange and can answer follow-up questions.
res2 <- agent$invoke("Which of those top-3 products had the highest revenue?")
cat("Assistant:", res2$content, "\n")
