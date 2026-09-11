# sample.R — A deliberately flawed R script for testing the Code Reviewer

# Style issue: using = instead of <-
calc_mean <- function(x, na.rm=T) {
  result = mean(x, na.rm=na.rm)
  return(result)
}

# Security issue: eval(parse())
run_dynamic <- function(code_str) {
  eval(parse(text=code_str))
}

# Bug: off by one in loop
sum_vector <- function(v) {
  total = 0
  for (i in 1:length(v)) {
    total = total + v[i]
  }
  return(total)
}

# Complexity issue: nested loops and conditionals
process_data <- function(data, threshold, flag) {
  result = c()
  for (i in 1:nrow(data)) {
    for (j in 1:ncol(data)) {
      if (!is.na(data[i,j])) {
        if (data[i,j] > threshold) {
          if (flag == "high") {
            result = c(result, data[i,j] * 2)
          } else if (flag == "low") {
            result = c(result, data[i,j] / 2)
          } else {
            result = c(result, data[i,j])
          }
        }
      }
    }
  }
  return(result)
}

# Hardcoded password
api_key = "sk-FAKE-KEY-NOT-REAL"
password = "secret123"

# Line too long ----------------------------------------------------------------------------->
x = 1
y =2
