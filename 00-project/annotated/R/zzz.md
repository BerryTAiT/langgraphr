# langgraphr/R/zzz.R

<!-- TARGET: langgraphr/R/zzz.R -->

> Package lifecycle. Loads a private state environment and cleans up the hidden
> server when the package unloads.

```r
# zzz.R - package load/unload hooks for langgraphr.
#
# We keep one private environment (.lg_env) for package-wide state.
# It stores the handle of the hidden server process so that we can
# stop the server when the package is unloaded (or when R closes).

# .lg_env is a fresh, empty environment that only this package can see.
# Using emptyenv() as its parent means it does NOT inherit R's search path.
.lg_env <- new.env(parent = emptyenv())

# .lg_env$proc will hold the processx handle of the running server.
# It starts as NULL, which means "no server process is being tracked yet".
.lg_env$proc <- NULL

# .onLoad runs once when the package is attached (library(langgraphr)).
# We use it to document the tuning options users can set with options().
.onLoad <- function(libname, pkgname) {
  # langgraphr.port   - which port the hidden server listens on (default 8123)
  # langgraphr.python - explicit path to python or uv (otherwise discovered)
  # langgraphr.timeout- seconds to wait for the server to become healthy
  # langgraphr.debug  - TRUE prints server logs to the R console
  # We do nothing here; the options are read lazily where they are needed.
  invisible(NULL)
}

# .onUnload runs when the package is detached (or R shuts down).
# We stop the hidden server so we never leave orphan processes behind.
.onUnload <- function(libpath) {
  # lg_stop_server() is defined in server.R; calling it here kills the
  # background server process if one is running, then clears the handle.
  lg_stop_server()
}
```
