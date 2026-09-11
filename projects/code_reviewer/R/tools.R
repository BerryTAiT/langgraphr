# tools.R — Code Reviewer Agent tools
# All tools use base R only — no external packages
#
# Tools exposed to the ReAct agent:
#   parse_check(code)       — verify syntax via parse()
#   test_run(code, input)   — eval code with sample input, capture output
#   style_check(code)       — check naming, spacing, indentation
#   security_check(code)   — flag system(), eval(parse()), file ops
#   refactor_code(code)     — return cleaned/improved code
#   complexity_check(code)  — cyclomatic complexity estimate
#   find_functions(code)   — list all function definitions
#   check_dependencies(code) — find library() / require() calls

# ---- Shared state ----
.code_env <- new.env(parent = emptyenv())

set_code <- function(code) {
  .code_env$code <- code
}

get_code <- function() {
  .code_env$code %||% ""
}

# ---- Tool implementations ----

parse_check <- function(code = NULL) {
  code <- code %||% get_code()
  if (!nzchar(code)) return("No code provided.")

  result <- tryCatch({
    parsed <- parse(text = code)
    n_funcs <- sum(grepl("^function", as.character(parsed)))
    n_assigns <- sum(grepl("<-", sapply(parsed, function(x) deparse(x)[1])))
    sprintf("Syntax OK. %d expression(s), %d function(s), %d assignment(s).",
            length(parsed), n_funcs, n_assigns)
  }, error = function(e) {
    sprintf("Syntax ERROR: %s", conditionMessage(e))
  })
  result
}

test_run <- function(code = NULL, input = NULL) {
  code <- code %||% get_code()
  if (!nzchar(code)) return("No code provided.")

  result <- tryCatch({
    parsed <- parse(text = code)
    env <- new.env(parent = parent.frame())

    # If input provided, evaluate it first
    if (!is.null(input) && nzchar(input)) {
      eval(parse(text = input), envir = env)
    }

    # Evaluate the code
    for (expr in parsed) {
      eval(expr, envir = env)
    }

    # Capture ls() to show what was created
    objects <- ls(envir = env)
    if (length(objects) == 0) {
      "Code ran successfully. No objects created."
    } else {
      obj_summary <- sapply(objects, function(obj_name) {
        obj <- get(obj_name, envir = env)
        cls <- class(obj)[1]
        if (is.function(obj)) {
          sprintf("%s: function(%s)", obj_name,
                  paste(names(formals(obj)), collapse = ", "))
        } else if (is.data.frame(obj)) {
          sprintf("%s: data.frame [%d x %d]", obj_name, nrow(obj), ncol(obj))
        } else if (is.vector(obj) && length(obj) > 1) {
          sprintf("%s: %s [%d]", obj_name, cls, length(obj))
        } else {
          sprintf("%s: %s = %s", obj_name, cls, toString(obj)[1])
        }
      })
      paste("Code ran successfully. Objects created:\n",
            paste(obj_summary, collapse = "\n"))
    }
  }, error = function(e) {
    sprintf("Runtime ERROR: %s", conditionMessage(e))
  })
  result
}

style_check <- function(code = NULL) {
  code <- code %||% get_code()
  if (!nzchar(code)) return("No code provided.")

  lines <- strsplit(code, "\n")[[1]]
  issues <- character(0)

  for (i in seq_along(lines)) {
    line <- lines[i]

    # Check: using = instead of <-
    if (grepl("^[^!<>=]*[^<>!]=[ ^=]", line) && !grepl("==|!=|<=|>=", line)) {
      if (grepl("\\w+\\s*=\\s*", line) && !grepl("function\\s*\\(", line)) {
        issues <- c(issues, sprintf("Line %d: Use '<-' instead of '=' for assignment.", i))
      }
    }

    # Check: T/F instead of TRUE/FALSE
    if (grepl("\\bT\\b", line) && !grepl("TRUE", line)) {
      issues <- c(issues, sprintf("Line %d: Use 'TRUE' instead of 'T'.", i))
    }
    if (grepl("\\bF\\b", line) && !grepl("FALSE", line)) {
      issues <- c(issues, sprintf("Line %d: Use 'FALSE' instead of 'F'.", i))
    }

    # Check: no space around operators
    if (grepl("\\w[+*/-]\\w", line) && !grepl("function|<-|=", line)) {
      issues <- c(issues, sprintf("Line %d: Add spaces around operators.", i))
    }

    # Check: line too long
    if (nchar(line) > 80) {
      issues <- c(issues, sprintf("Line %d: Line exceeds 80 characters (%d).", i, nchar(line)))
    }

    # Check: tab characters
    if (grepl("\t", line)) {
      issues <- c(issues, sprintf("Line %d: Use spaces, not tabs.", i))
    }

    # Check: trailing whitespace
    if (grepl("\\s+$", line)) {
      issues <- c(issues, sprintf("Line %d: Trailing whitespace.", i))
    }
  }

  if (length(issues) == 0) {
    "Style OK. No issues found."
  } else {
    paste("Style issues found:", paste(issues, collapse = "\n"), sep = "\n")
  }
}

security_check <- function(code = NULL) {
  code <- code %||% get_code()
  if (!nzchar(code)) return("No code provided.")

  lines <- strsplit(code, "\n")[[1]]
  risks <- character(0)

  patterns <- list(
    list(pat = "system\\(", risk = "system() call — executes shell commands"),
    list(pat = "system2\\(", risk = "system2() call — executes shell commands"),
    list(pat = "eval\\(parse\\(", risk = "eval(parse()) — arbitrary code execution"),
    list(pat = "source\\(", risk = "source() — loads external code"),
    list(pat = "file\\.remove\\(", risk = "file.remove() — deletes files"),
    list(pat = "file\\.unlink\\(", risk = "file.unlink() — deletes files"),
    list(pat = "unlink\\(", risk = "unlink() — deletes files/directories"),
    list(pat = "download\\.file\\(", risk = "download.file() — downloads from internet"),
    list(pat = "url\\(", risk = "url() — connects to external URL"),
    list(pat = "\\.Renviron", risk = "Accessing .Renviron — may expose secrets"),
    list(pat = "Sys\\.getenv\\(", risk = "Sys.getenv() — reads environment variables"),
    list(pat = "Sys\\.setenv\\(", risk = "Sys.setenv() — modifies environment variables"),
    list(pat = "writeLines\\(.*password", risk = "Possible hardcoded password"),
    list(pat = "password\\s*=", risk = "Possible hardcoded password"),
    list(pat = "api_key\\s*=", risk = "Possible hardcoded API key"),
    list(pat = "token\\s*=", risk = "Possible hardcoded token")
  )

  for (i in seq_along(lines)) {
    for (p in patterns) {
      if (grepl(p$pat, lines[i], ignore.case = TRUE)) {
        risks <- c(risks, sprintf("Line %d: %s", i, p$risk))
      }
    }
  }

  if (length(risks) == 0) {
    "No security issues found."
  } else {
    paste("Security concerns:", paste(risks, collapse = "\n"), sep = "\n")
  }
}

refactor_code <- function(code = NULL) {
  code <- code %||% get_code()
  if (!nzchar(code)) return("No code provided.")

  lines <- strsplit(code, "\n")[[1]]
  refactored <- code

  # Replace = with <- for assignments (not in function args or ==)
  refactored <- gsub("(\\w+)\\s*=\\s*(?!=)", "\\1 <- \\2", refactored, perl = TRUE)

  # Replace T with TRUE (standalone, not in TRUE)
  refactored <- gsub("\\bT\\b", "TRUE", refactored, perl = TRUE)
  refactored <- gsub("\\bF\\b", "FALSE", refactored, perl = TRUE)

  # Remove trailing whitespace
  refactored <- gsub("\\s+$", "", refactored, perl = TRUE)

  # Replace tabs with 2 spaces
  refactored <- gsub("\t", "  ", refactored)

  # Add space after comma
  refactored <- gsub(",(\\S)", ", \\1", refactored, perl = TRUE)

  # Add spaces around <- if missing
  refactored <- gsub("(\\w)<-(\\w)", "\\1 <- \\2", refactored, perl = TRUE)

  if (identical(refactored, code)) {
    "No refactoring needed. Code is already clean."
  } else {
    sprintf("Refactored code:\n%s", refactored)
  }
}

complexity_check <- function(code = NULL) {
  code <- code %||% get_code()
  if (!nzchar(code)) return("No code provided.")

  result <- tryCatch({
    parsed <- parse(text = code)
    total_complexity <- 0
    func_details <- character(0)

    for (expr in parsed) {
      code_str <- deparse(expr)

      # Count decision points
      decisions <- 0
      decisions <- decisions + length(grep("\\bif\\b", code_str))
      decisions <- decisions + length(grep("\\belse\\s+if\\b", code_str))
      decisions <- decisions + length(grep("\\bfor\\b", code_str))
      decisions <- decisions + length(grep("\\bwhile\\b", code_str))
      decisions <- decisions + length(grep("\\brepeat\\b", code_str))
      decisions <- decisions + length(grep("\\|\\|", code_str))
      decisions <- decisions + length(grep("&&", code_str))
      decisions <- decisions + length(grep("\\?[^=]", code_str))

      # Check for function definitions
      func_lines <- grep("function\\s*\\(", code_str)
      for (fl in func_lines) {
        func_name <- sub(".*?(\\w+)\\s*<-[\\s]*function.*", "\\1", code_str[fl])
        if (!nzchar(func_name)) func_name <- "(anonymous)"
        func_complexity <- decisions + 1
        total_complexity <- total_complexity + func_complexity
        func_details <- c(func_details,
          sprintf("  %s: complexity %d", func_name, func_complexity))
      }

      if (length(func_lines) == 0 && decisions > 0) {
        total_complexity <- total_complexity + decisions + 1
        func_details <- c(func_details,
          sprintf("  (top-level): complexity %d", decisions + 1))
      }
    }

    rating <- if (total_complexity <= 5) "Low (easy to maintain)"
              else if (total_complexity <= 10) "Moderate"
              else if (total_complexity <= 20) "High (consider refactoring)"
              else "Very High (refactor urgently)"

    sprintf("Cyclomatic Complexity: %d (%s)\n%s",
            total_complexity, rating,
            if (length(func_details) > 0) paste(func_details, collapse = "\n") else "")
  }, error = function(e) {
    sprintf("Complexity check error: %s", conditionMessage(e))
  })
  result
}

find_functions <- function(code = NULL) {
  code <- code %||% get_code()
  if (!nzchar(code)) return("No code provided.")

  lines <- strsplit(code, "\n")[[1]]
  funcs <- character(0)

  for (i in seq_along(lines)) {
    if (grepl("<-\\s*function\\s*\\(", lines[i]) || grepl("=\\s*function\\s*\\(", lines[i])) {
      name <- sub(".*?(\\w+)\\s*(<-|=)\\s*function.*", "\\1", lines[i])
      # Extract args
      args_start <- regmatches(lines[i], regexpr("function\\s*\\(.*?\\)", lines[i]))
      if (nzchar(args_start) && !is.na(args_start)) {
        funcs <- c(funcs, sprintf("Line %d: %s %s", i, name, args_start))
      } else {
        # Multi-line function — just show name
        funcs <- c(funcs, sprintf("Line %d: %s(...)", i, name))
      }
    }
  }

  if (length(funcs) == 0) {
    "No function definitions found."
  } else {
    sprintf("Functions found (%d):\n%s", length(funcs), paste(funcs, collapse = "\n"))
  }
}

check_dependencies <- function(code = NULL) {
  code <- code %||% get_code()
  if (!nzchar(code)) return("No code provided.")

  libs <- unique(c(
    regmatches(code, gregexpr("(?<=library\\()\\w+", code, perl = TRUE))[[1]],
    regmatches(code, gregexpr("(?<=require\\()\\w+", code, perl = TRUE))[[1]]
  ))

  if (length(libs) == 0) {
    "No external dependencies. Uses base R only."
  } else {
    sprintf("Dependencies (%d): %s", length(libs), paste(libs, collapse = ", "))
  }
}

# ---- Tool registry for the agent ----
code_review_tools <- function() {
  list(
    parse_check = parse_check,
    test_run = test_run,
    style_check = style_check,
    security_check = security_check,
    refactor_code = refactor_code,
    complexity_check = complexity_check,
    find_functions = find_functions,
    check_dependencies = check_dependencies
  )
}

code_review_tool_descriptions <- function() {
  paste(
    "Available tools (use EXACT names):",
    "  parse_check(code) - Check R syntax via parse(). code is optional.",
    "  test_run(code, input) - Execute code in sandbox. input is optional sample R code to set up.",
    "  style_check(code) - Check naming, spacing, line length, T/F usage.",
    "  security_check(code) - Flag system(), eval(parse()), file ops, hardcoded secrets.",
    "  refactor_code(code) - Return cleaned code (= -> <-, T -> TRUE, etc.).",
    "  complexity_check(code) - Estimate cyclomatic complexity.",
    "  find_functions(code) - List all function definitions with args.",
    "  check_dependencies(code) - Find library()/require() calls.",
    sep = "\n")
}
