# legacy_utils.R - dangerous legacy utilities.

eval_expr = function(code) {
  eval(parse(text = code))
}

double_it = function(x) {
  eval(parse(text = "x * 2"))
}

old_sort = function(x) {
  .Internal(sort(x, FALSE))
}
