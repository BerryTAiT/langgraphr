# test.R - verify the agent framework works end-to-end

compat <- file.path(getwd(), "R", "modules_compat.R")
if (!file.exists(compat)) {
  compat <- file.path(dirname(dirname(getwd())), "data_detective", "R", "modules_compat.R")
}
source(compat, local = FALSE)
cat("Loaded compat helpers from:", compat, "\n\n")

cat("\n=== Instantiate objects ===\n")
saver <- LgInMemorySaver$new()
cat("saver:", class(saver)[1], "db_type:", saver$db_type, "\n")

store <- LgStore$new()
cat("store:", class(store)[1], "\n")

# Test store
store$put(c("test", "ns"), "key1", list(value="hello"))
item <- store$get(c("test", "ns"), "key1")
cat("store get:", item$value$value, "\n\n")

# Test checkpoint
cp <- lg_checkpoint(
  channel_values = list(messages = "test"),
  channel_versions = list(messages = 1)
)
cat("checkpoint class:", class(cp)[1], "\n")
cat("checkpoint id:", cp$id, "\n")
cat("checkpoint ts:", cp$ts, "\n\n")

meta <- lg_checkpoint_metadata(source="test", step=1)
cat("metadata class:", class(meta)[1], "\n")
cat("metadata step:", meta$step, "\n\n")

# Save to saver
config <- list(configurable = list(thread_id="t1", checkpoint_ns=""))
cat("Saving with config:", config$configurable$thread_id, "\n")
saver$put(config, cp, meta, list())
cat("storage after put:\n")
cat("  threads:", names(saver$storage), "\n")
cat("  storage[[t1]] keys:", names(saver$storage[["t1"]]), "\n")
cat("  storage[[t1]][[root ns]] keys:",
    names(saver$storage[["t1"]][["__root__"]]), "\n\n")

# Retrieve
tuple <- saver$get_tuple(config)
cat("retrieved tuple:", !is.null(tuple), "\n")
if (!is.null(tuple)) {
  cat("  checkpoint id:", tuple$checkpoint$id, "\n")
  cat("  metadata step:", tuple$metadata$step, "\n")
} else {
  cat("  DEBUG: get_tuple returned NULL\n")
  cat("  storage keys:", names(saver$storage), "\n")
  if (!is.null(saver$storage[["t1"]])) {
    cat("  t1 keys:", names(saver$storage[["t1"]]), "\n")
    if (!is.null(saver$storage[["t1"]][[""]])) {
      cat("  t1/'' keys:", names(saver$storage[["t1"]][[""]]), "\n")
    }
  }
}

# List history
history <- saver$list(config)
cat("history count:", length(history), "\n\n")

# Test lg_thread_id from package
cat("thread_id:", langgraphr::lg_thread_id(), "\n")
cat("lg_call_model in pkg:", exists("lg_call_model", where=asNamespace("langgraphr")), "\n")

cat("\n=== Framework checks complete ===\n")
