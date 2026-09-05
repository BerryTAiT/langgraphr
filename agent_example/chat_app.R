# chat_app.R - a Shiny chat UI for your langgraphr agent.
#
# Run in the R console:
#   source("agent_example/chat_app.R")
# Then open the app in the browser and chat. Plots drawn by agent tools
# appear in the app just like they would in your R session.

dotenv::load_dot_env("agent_example/.env")

library(langgraphr)
library(shiny)
library(bslib)

# The R tools the agent can call.
summarize_numbers <- function(numbers) {
  numbers <- as.numeric(numbers)
  list(n = length(numbers), mean = mean(numbers),
       min = min(numbers), max = max(numbers))
}
format_usd <- function(value) sprintf("$%.2f", as.numeric(value))
plot_revenue <- function(revenue) {
  barplot(as.numeric(revenue), names.arg = seq_along(revenue),
          ylab = "revenue", main = "Revenue by entry")
  invisible("Bar plot rendered.")
}

ui <- page_sidebar(
  title = "langgraphr agent",
  sidebar = sidebar(
    p("Chat with an AI agent whose tools are R functions."),
    actionButton("reset", "New conversation", class = "btn-outline-primary"),
    width = 250
  ),
  card(
    fill = TRUE,
    verbatimTextOutput("chat", fill = TRUE)
  ),
  layout_column_wrap(
    width = 1,
    textAreaInput("msg", NULL, placeholder = "Type a message...",
                  rows = 2, resize = "none"),
    actionButton("send", "Send", class = "btn-primary")
  ),
  fillable = TRUE
)

server <- function(input, output, session) {
  # Conversation transcript shown in the card.
  transcript <- reactiveVal("Agent ready. Ask me anything.\n")

  # One agent per session; a fresh thread id resets memory.
  agent <- reactiveVal(NULL)

  output$chat <- renderVerbatimTextOutput(transcript())

  observeEvent(input$reset, {
    a <- agent()
    if (!is.null(a)) a$reset()
    transcript("Started a new conversation.\n")
  })

  observeEvent(input$send, {
    msg <- trimws(input$msg)
    req(nzchar(msg))
    # Lazily create the agent on first message.
    if (is.null(agent())) {
      a <- lg_connect()
      a$add_tool(summarize_numbers,
                 description = "Compute n, mean, min, max of a numeric vector")
      a$add_tool(format_usd,
                 description = "Format a number as US dollars")
      a$add_tool(plot_revenue,
                 description = paste0(
                   "Draw a bar plot of the given numeric revenue values ",
                   "in the user's session; call this when a plot is asked for"))
      agent(a)
    }
    transcript(paste0(transcript(), "You: ", msg, "\n"))
    updateTextAreaInput(session, "msg", value = "")
    # Blocking invoke; show a thinking note first.
    transcript(paste0(transcript(), "Agent: ... thinking\n"))
    res <- tryCatch(agent()$invoke(msg), error = function(e) {
      list(content = paste("Error:", conditionMessage(e)))
    })
    transcript(paste0(transcript(), "Agent: ", res$content, "\n\n"))
  })
}

shinyApp(ui, server)
