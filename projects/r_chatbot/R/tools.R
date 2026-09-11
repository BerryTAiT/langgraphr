# tools.R - R functions the chatbot may call, plus registration.
#
# HOW TO ADD A NEW TOOL (the whole process):
#   1. Write one ordinary R function below.
#   2. Add ONE `agent$add_tool(<function>, description = "...")` line
#      inside register_tools().
# Nothing else needs to change: the model decides on its own when a
# conversation needs the tool, and the hidden server pauses the run so the
# function executes right here in your R session.

# session_info_tool() reports the user's R environment: version, platform,
# working directory and which packages are currently loaded. The bot calls
# it by itself when the user asks e.g. "what's my R environment?".
session_info_tool <- function() {
  list(
    r_version        = R.version.string,
    platform         = R.version$platform,
    working_directory = getwd(),
    loaded_packages  = paste(sort(loadedNamespaces()), collapse = ", ")
  )
}

# tool_registry() - the single source of truth for the bot's tools.
# Both front ends (console main.R and Shiny app.R) read from here, so
# adding a tool below updates every front end at once.
tool_registry <- function() {
  list(
    list(
      fn = session_info_tool,
      description = paste0(
        "Report the user's R environment: R version, platform, working ",
        "directory and loaded packages. Call this whenever the user asks ",
        "about their R setup or environment."
      )
    )
    # Add future tools here as one more list(fn = ..., description = ...).
  )
}

# register_tools(agent) wires every tool in the registry onto the agent.
register_tools <- function(agent) {
  for (t in tool_registry()) {
    agent$add_tool(t$fn, description = t$description)
  }
  # Return the agent so calls can be chained.
  agent
}
