# test2.R - debug InMemorySaver put method directly

compat <- file.path(getwd(), "R", "modules_compat.R")
if (!file.exists(compat)) {
  compat <- file.path(dirname(dirname(getwd())), "data_detective", "R", "modules_compat.R")
}
source(compat, local = FALSE)

saver <- LgInMemorySaver$new()

# Direct test of nested list storage
cat("=== Direct nested list test ===\n")
s <- list()
s[["t1"]] <- list()
s[["t1"]][[""]] <- list()
s[["t1"]][[""]][["cp1"]] <- "value"
cat("Direct: t1 keys:", names(s[["t1"]]), "\n")
cat("Direct: t1/'' keys:", names(s[["t1"]][[""]]), "\n")
cat("Direct: value:", s[["t1"]][[""]][["cp1"]], "\n\n")

# Test with the saver object
cat("=== Saver test ===\n")
cp <- lg_checkpoint(
  channel_values = list(messages = "test"),
  channel_versions = list(messages = 1)
)
meta <- lg_checkpoint_metadata(source="test", step=1)
config <- list(configurable = list(thread_id="t1", checkpoint_ns=""))

cat("Before put - storage:", length(saver$storage), "items\n")
cat("Before put - storage class:", class(saver$storage), "\n")

# Manually do what put does
s <- saver$storage
cat("s is self$storage:", identical(s, saver$storage), "\n")
cat("s length before:", length(s), "\n")
s[["t1"]] <- list()
cat("s length after t1:", length(s), "\n")
cat("s t1 keys:", names(s[["t1"]]), "\n")
s[["t1"]][[""]] <- list()
cat("s t1/'' keys:", names(s[["t1"]][[""]]), "\n")
s[["t1"]][[""]][[cp$id]] <- "checkpoint_value"
cat("s t1/'' keys after cp:", names(s[["t1"]][[""]]), "\n")
saver$storage <- s
cat("After assign - storage length:", length(saver$storage), "\n")
cat("After assign - storage t1 keys:", names(saver$storage[["t1"]]), "\n")
cat("After assign - storage t1/'' keys:", names(saver$storage[["t1"]][[""]]), "\n")
cat("After assign - storage t1/''/cp:", saver$storage[["t1"]][[""]][[cp$id]], "\n")
