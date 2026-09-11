# data_prep.R - legacy configuration helpers.

load_config = function(path) {
  lines = readLines(path)
  cfg = list()
  for (l in lines) {
    parts = strsplit(l, "=")[[1]]
    if (length(parts) == 2) {
      cfg[[trimws(parts[1])]] = trimws(parts[2])
    }
  }
  return(cfg)
}

flag_ready = function(cfg) {
  if (is.null(cfg$mode)) return(F)
  return(T)
}
