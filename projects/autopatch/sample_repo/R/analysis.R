# analysis.R - legacy analysis helpers.

col_means_df = function(df) {
  out = sapply(df, mean)
  out
}

row_seq = function(df) {
  1:nrow(df)
}

make_label = function(prefix, n) {
  paste(prefix, 1:n, sep = "_")
}
