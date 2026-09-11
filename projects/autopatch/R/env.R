# env.R - locate the project directory and load .env credentials.
# Proven pattern from projects/code_reviewer (searches call frames for the
# script location, then walks up looking for a .env file).

ap_script_dir <- function() {
  tryCatch({
    frame_files <- lapply(sys.frames(), function(f) f$ofile)
    non_null <- which(!sapply(frame_files, is.null))
    if (length(non_null) > 0) {
      return(dirname(normalizePath(frame_files[[non_null[1]]], winslash = "/")))
    }
    for (c in c("projects/autopatch", "autopatch", ".")) {
      if (dir.exists(file.path(c, "R"))) return(normalizePath(c, winslash = "/"))
    }
    normalizePath(".", winslash = "/")
  }, error = function(e) normalizePath(".", winslash = "/"))
}

ap_load_env <- function(script_dir) {
  candidates <- c(
    file.path(script_dir, ".env"),
    file.path(dirname(script_dir), ".env"),
    file.path(dirname(dirname(script_dir)), ".env"),
    file.path(dirname(dirname(dirname(script_dir))), ".env"),
    file.path(dirname(script_dir), "data_detective", ".env"),
    file.path(dirname(script_dir), "code_reviewer", ".env")
  )
  for (env_path in candidates) {
    if (file.exists(env_path)) {
      lines <- readLines(env_path, warn = FALSE)
      for (line in lines) {
        line <- trimws(line)
        if (!nchar(line) || startsWith(line, "#")) next
        eq_pos <- regexpr("=", line)
        if (eq_pos > 0) {
          key <- trimws(substr(line, 1, eq_pos - 1))
          val <- trimws(substr(line, eq_pos + 1, nchar(line)))
          val <- gsub('^"|^\'|"$|\'$', "", val)
          do.call(Sys.setenv, stats::setNames(list(val), key))
        }
      }
      return(invisible(env_path))
    }
  }
  invisible(NULL)
}
