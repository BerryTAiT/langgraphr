# modules_compat.R - self-contained helpers extracted from the former
# langgraphr module/ experiment (deleted 2026-09-09). This project needs
# only these: checkpoint constructors and tool-call parsing.

# Latest checkpoint format version (Python: langgraph.checkpoint.base)
LG_LATEST_VERSION <- 2L

# Sortable checkpoint ID mimicking Python's uuid6 monotonic ordering
lg_checkpoint_id <- function() {
  now <- Sys.time()
  ts <- format(now, "%Y%m%d%H%M%S")
  secs <- as.numeric(now)
  ms <- sprintf("%06d", as.integer((secs - floor(secs)) * 1e6))
  rand <- sprintf("%010d", as.integer(stats::runif(1, 0, 1e9)))
  paste0(ts, ms, rand)
}

# ISO 8601 UTC timestamp with microseconds
lg_timestamp_utc <- function() {
  now <- Sys.time()
  attr(now, "tzone") <- "UTC"
  format(now, "%Y-%m-%dT%H:%M:%OS6Z")
}

# Python: langgraph.checkpoint.base.CheckpointMetadata
lg_checkpoint_metadata <- function(source = "input", step = -1,
                                    parents = list(),
                                    run_id = NULL,
                                    counters_since_delta_snapshot = NULL) {
  structure(
    list(
      source = source,
      step = step,
      parents = parents,
      run_id = run_id,
      counters_since_delta_snapshot = counters_since_delta_snapshot
    ),
    class = "lg_checkpoint_metadata"
  )
}

# Python: langgraph.checkpoint.base.Checkpoint
lg_checkpoint <- function(channel_values = list(),
                           channel_versions = list(),
                           versions_seen = list(),
                           pending_sends = list(),
                           updated_channels = NULL,
                           version = LG_LATEST_VERSION,
                           id = NULL,
                           ts = NULL) {
  structure(
    list(
      v = version,
      id = if (is.null(id)) lg_checkpoint_id() else id,
      ts = if (is.null(ts)) lg_timestamp_utc() else ts,
      channel_values = channel_values,
      channel_versions = channel_versions,
      versions_seen = versions_seen,
      pending_sends = pending_sends,
      updated_channels = updated_channels
    ),
    class = "lg_checkpoint"
  )
}

# Python: langgraph.checkpoint.base.CheckpointTuple
lg_checkpoint_tuple <- function(config, checkpoint, metadata,
                                parent_config = NULL,
                                pending_writes = NULL) {
  structure(
    list(
      config = config,
      checkpoint = checkpoint,
      metadata = metadata,
      parent_config = parent_config,
      pending_writes = if (is.null(pending_writes)) list() else pending_writes
    ),
    class = "lg_checkpoint_tuple"
  )
}

is_checkpoint <- function(x) inherits(x, "lg_checkpoint")

# Python: langgraph.checkpoint.base.copy_checkpoint
lg_copy_checkpoint <- function(checkpoint) {
  if (!is_checkpoint(checkpoint)) {
    stop("Expected a Checkpoint from lg_checkpoint()")
  }
  structure(
    list(
      v = checkpoint$v,
      id = checkpoint$id,
      ts = checkpoint$ts,
      channel_values = if (!is.null(checkpoint$channel_values)) lapply(checkpoint$channel_values, function(x) x) else list(),
      channel_versions = if (!is.null(checkpoint$channel_versions)) lapply(checkpoint$channel_versions, function(x) x) else list(),
      versions_seen = if (!is.null(checkpoint$versions_seen)) lapply(checkpoint$versions_seen, function(v) lapply(v, function(x) x)) else list(),
      pending_sends = if (!is.null(checkpoint$pending_sends)) lapply(checkpoint$pending_sends, function(x) x) else list(),
      updated_channels = checkpoint$updated_channels
    ),
    class = "lg_checkpoint"
  )
}

# Python: langgraph.checkpoint.memory.InMemorySaver
# NOTE: R cannot look up list elements by the empty-string name
# (l[[""]] returns NULL even after l[[""]] <- v), so the default
# namespace "" is stored under the internal key "__root__".
LgInMemorySaver <- R6::R6Class("LgInMemorySaver",
  public = list(
    storage = NULL,
    writes = NULL,
    db_type = NULL,

    initialize = function() {
      self$storage <- list()
      self$writes <- list()
      self$db_type <- "memory"
    },

    .ns_key = function(checkpoint_ns) {
      if (is.null(checkpoint_ns) || !nchar(checkpoint_ns)) "__root__" else checkpoint_ns
    },

    get_tuple = function(config) {
      conf <- config$configurable
      if (is.null(conf)) return(NULL)
      thread_id <- conf$thread_id
      if (is.null(thread_id)) return(NULL)
      checkpoint_ns <- if (is.null(conf$checkpoint_ns)) "" else conf$checkpoint_ns
      thread_storage <- self$storage[[thread_id]]
      if (is.null(thread_storage)) return(NULL)
      ns_storage <- thread_storage[[self$.ns_key(checkpoint_ns)]]
      if (is.null(ns_storage)) return(NULL)

      checkpoint_id <- conf$checkpoint_id
      if (!is.null(checkpoint_id)) {
        tuple <- ns_storage[[checkpoint_id]]
        if (is.null(tuple)) return(NULL)
      } else {
        if (length(ns_storage) == 0) return(NULL)
        sorted_keys <- sort(names(ns_storage), decreasing = TRUE)
        tuple <- ns_storage[[sorted_keys[1]]]
      }

      task_id_key <- paste(c(tuple$checkpoint$id, conf$checkpoint_ns %||% ""),
                           collapse = "|")
      pending_writes <- self$writes[[task_id_key]]
      tuple$pending_writes <- pending_writes %||% list()
      tuple
    },

    list = function(config, filter = NULL, before = NULL, limit = NULL) {
      conf <- if (!is.null(config)) config$configurable else NULL
      thread_id <- if (!is.null(conf)) conf$thread_id else NULL
      checkpoint_ns <- if (!is.null(conf)) (if (is.null(conf$checkpoint_ns)) "" else conf$checkpoint_ns) else ""

      if (!is.null(thread_id)) {
        thread_storage <- self$storage[[thread_id]]
        if (is.null(thread_storage)) return(list())
        ns_storage <- thread_storage[[self$.ns_key(checkpoint_ns)]]
        if (is.null(ns_storage)) return(list())
      } else {
        ns_storage <- list()
        for (th in names(self$storage)) {
          for (ns in names(self$storage[[th]])) {
            ns_storage <- c(ns_storage, self$storage[[th]][[ns]])
          }
        }
      }

      tuples <- unname(ns_storage)
      if (length(tuples) == 0) return(list())

      sorted_idx <- order(sapply(tuples, function(t) t$checkpoint$id),
                          decreasing = TRUE)
      tuples <- tuples[sorted_idx]

      if (!is.null(before) && !is.null(before$configurable$checkpoint_id)) {
        before_id <- before$configurable$checkpoint_id
        tuples <- Filter(function(t) t$checkpoint$id < before_id, tuples)
      }

      if (!is.null(limit) && length(tuples) > limit) {
        tuples <- tuples[seq_len(limit)]
      }

      tuples
    },

    put = function(config, checkpoint, metadata, new_versions) {
      conf <- config$configurable
      thread_id <- conf$thread_id
      checkpoint_ns <- if (is.null(conf$checkpoint_ns)) "" else conf$checkpoint_ns
      ns_key <- self$.ns_key(checkpoint_ns)
      checkpoint_id <- checkpoint$id

      # Stage nested structures in locals, write back with single-level
      # assignment (deep chained [[<- on self$... does not persist in R6).
      thread_storage <- self$storage[[thread_id]]
      if (is.null(thread_storage)) thread_storage <- list()
      ns_storage <- thread_storage[[ns_key]]
      if (is.null(ns_storage)) ns_storage <- list()

      parent_config <- if (!is.null(conf$checkpoint_id)) {
        list(configurable = list(
          thread_id = thread_id,
          checkpoint_ns = checkpoint_ns,
          checkpoint_id = conf$checkpoint_id
        ))
      } else NULL

      ns_storage[[checkpoint_id]] <- lg_checkpoint_tuple(
        config = list(configurable = list(
          thread_id = thread_id,
          checkpoint_ns = checkpoint_ns,
          checkpoint_id = checkpoint_id
        )),
        checkpoint = lg_copy_checkpoint(checkpoint),
        metadata = metadata,
        parent_config = parent_config
      )

      thread_storage[[ns_key]] <- ns_storage
      self$storage[[thread_id]] <- thread_storage

      list(configurable = list(
        thread_id = thread_id,
        checkpoint_ns = checkpoint_ns,
        checkpoint_id = checkpoint_id
      ))
    },

    delete_thread = function(thread_id) {
      self$storage[[thread_id]] <- NULL
      invisible(NULL)
    }
  )
)

# Python: langgraph.store.memory.InMemoryStore
LgStore <- R6::R6Class("LgStore",
  public = list(
    items = NULL,

    initialize = function() {
      self$items <- list()
    },

    put = function(namespace, key, value) {
      ns_key <- paste(namespace, collapse = "/")
      if (is.null(self$items[[ns_key]])) self$items[[ns_key]] <- list()

      existing <- self$items[[ns_key]][[key]]
      now <- Sys.time()
      created <- if (is.null(existing)) now else existing$created_at

      self$items[[ns_key]][[key]] <- list(
        value = value,
        key = key,
        namespace = namespace,
        created_at = created,
        updated_at = now
      )
      invisible(NULL)
    },

    get = function(namespace, key) {
      ns_key <- paste(namespace, collapse = "/")
      self$items[[ns_key]][[key]] %||% NULL
    },

    search = function(namespace_prefix, filter = NULL, limit = 10, offset = 0) {
      prefix_str <- paste(namespace_prefix, collapse = "/")
      results <- list()
      for (ns_key in names(self$items)) {
        if (startsWith(ns_key, prefix_str)) {
          for (key in names(self$items[[ns_key]])) {
            item <- self$items[[ns_key]][[key]]
            if (!is.null(filter)) {
              match <- all(vapply(names(filter), function(fk) {
                identical(item$value[[fk]], filter[[fk]])
              }, logical(1)))
              if (!match) next
            }
            results <- c(results, list(item))
          }
        }
      }
      if (offset > 0) results <- results[(offset + 1):length(results)]
      if (length(results) > limit) results <- results[1:limit]
      results
    },

    delete = function(namespace, key) {
      ns_key <- paste(namespace, collapse = "/")
      if (!is.null(self$items[[ns_key]])) {
        self$items[[ns_key]][[key]] <- NULL
      }
      invisible(NULL)
    }
  )
)

# Parse JSON tool_calls out of an LLM response string
lg_parse_tool_calls <- function(response) {
  # perl=TRUE required: TRE does not support [\s\S]
  json_match <- regmatches(
    response,
    regexpr('\\{[\\s\\S]*"tool_calls"[\\s\\S]*\\}', response, perl = TRUE)
  )

  if (length(json_match) == 0 || nchar(json_match) == 0) {
    return(list())
  }

  parsed <- tryCatch({
    jsonlite::fromJSON(json_match)
  }, error = function(e) NULL)

  if (is.null(parsed) || is.null(parsed$tool_calls)) {
    return(list())
  }

  if (is.data.frame(parsed$tool_calls)) {
    lapply(seq_len(nrow(parsed$tool_calls)), function(i) {
      as.list(parsed$tool_calls[i, ])
    })
  } else {
    parsed$tool_calls
  }
}
