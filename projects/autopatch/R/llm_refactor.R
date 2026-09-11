# llm_refactor.R - the LLM side of the refactor node.
# Calls the configured OpenAI-compatible model (DeepSeek via LANGGRAPHR_* in
# .env) through langgraphr's own lg_call_model(), so the refactor step needs
# no extra R packages. Returns NULL on any failure; the caller then falls
# back to the deterministic rule fixer.

llm_fix <- function(content, defects_json, prev = NULL, error_log = NULL) {
  dlist <- if (is.null(defects_json) || !nzchar(defects_json)) {
    list()
  } else {
    jsonlite::fromJSON(defects_json, simplifyVector = FALSE)
  }
  dtext <- if (length(dlist) == 0) {
    "none detected"
  } else {
    paste(vapply(dlist, function(d) {
      sprintf("- [%s/%s] line %s: %s (found: %s)",
              d$severity, d$category, d$line, d$desc, d$evidence)
    }, character(1)), collapse = "\n")
  }

  sys <- paste(
    "You are AutoPatch, an expert R code modernization engine.",
    "You receive one R source file and a defect list. Fix every listed",
    "defect while preserving all observable behavior.",
    "Standards: use <- for assignment (never =); use TRUE/FALSE (never T/F);",
    "replace fragile 1:nrow(df)/1:length(x) with seq_len(...); remove",
    "eval(parse(...)) and .Internal(); move hardcoded credentials to",
    "Sys.getenv(\"NAME\", \"\").",
    "Output ONLY the complete fixed R file. No markdown fences, no",
    "commentary, no partial snippets."
  )
  usr <- paste0("DEFECTS:\n", dtext, "\n\nR FILE TO FIX:\n", content)
  if (!is.null(error_log) && nzchar(error_log)) {
    usr <- paste0(usr, "\n\nA previous attempt FAILED the test suite:\n", error_log)
    if (!is.null(prev) && nzchar(prev)) {
      usr <- paste0(usr, "\n\nThe previous (broken) attempt was:\n", prev)
    }
    usr <- paste0(usr, "\n\nProduce a corrected complete file.")
  }

  msgs <- list(
    list(role = "system", content = sys),
    list(role = "user", content = usr)
  )
  out <- tryCatch(
    lg_call_model(msgs, temperature = 0),
    error = function(e) {
      cat("    [worker] model call failed:", conditionMessage(e), "\n")
      NULL
    }
  )
  if (is.null(out)) return(NULL)
  strip_fences(out)
}
