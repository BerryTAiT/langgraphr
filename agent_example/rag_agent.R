# rag_agent.R - a small RAG (retrieval-augmented generation) agent.
#
# Retrieval runs fully locally in base R (keyword-overlap scoring over a
# tiny corpus - swap in text2vec/embeddings for production scale), and the
# generation step calls the model from R via lg_call_model(). No Python,
# no vector-store service required.
#
# Run in the R console:
#   source("agent_example/rag_agent.R")

dotenv::load_dot_env("agent_example/.env")
library(langgraphr)

# ---- 1. A tiny knowledge base -------------------------------------------------
corpus <- c(
  "langgraphr is an R package for building AI agents on the LangGraph engine.",
  "The assistant path uses lg_connect() and registers R functions as tools.",
  "The graph path uses lg_graph(), lg_add_node() and lg_compile() to build
   stateful agent workflows whose nodes are R functions.",
  "Conversation memory is keyed by thread ids; lg_use_sqlite() makes it
   survive server restarts.",
  "The hidden server runs on 127.0.0.1:8123 and is managed by R.",
  "Model credentials are configured with the LANGGRAPHR_MODEL,
   LANGGRAPHR_API_KEY and LANGGRAPHR_BASE_URL environment variables."
)

# ---- 2. Local retrieval: stopword-filtered keyword scoring with IDF -----------
retrieve <- function(query, k = 2) {
  # Common words carry no meaning; drop them before scoring.
  stop_words <- c("how", "does", "do", "the", "and", "for", "with", "what",
                  "when", "which", "are", "can", "you", "use", "using",
                  "work", "works", "make", "this", "that", "from")
  # Tokenise into lowercase words, dropping short ones and stopwords.
  words <- tolower(strsplit(gsub("[^A-Za-z0-9 ]", " ", query), "\\s+")[[1]])
  words <- words[nchar(words) > 2 & !words %in% stop_words]
  if (length(words) == 0) return(corpus[seq_len(min(k, length(corpus)))])
  # IDF: words appearing in few documents are the informative ones
  # (so "memory" outranks "langgraphr", which is in most documents).
  df <- vapply(unique(words), function(w) {
    sum(vapply(corpus, function(doc) grepl(w, tolower(doc), fixed = TRUE),
               logical(1)))
  }, numeric(1))
  idf <- setNames(1 / log(1 + df), unique(words))
  # Score each document by the IDF weight of the query words it contains.
  scores <- vapply(corpus, function(doc) {
    doc_lower <- tolower(doc)
    sum(vapply(words, function(w) {
      if (grepl(w, doc_lower, fixed = TRUE)) idf[[w]] else 0
    }, numeric(1)))
  }, numeric(1))
  # Return the k best documents.
  corpus[order(scores, decreasing = TRUE)][seq_len(min(k, length(corpus)))]
}

# ---- 3. Build the RAG prompt and generate an answer ----------------------------
rag_answer <- function(query) {
  docs <- retrieve(query)
  context <- paste0("- ", docs, collapse = "\n")
  lg_call_model(list(
    list(role = "system", content = paste0(
      "Answer the user's question using ONLY the context below. ",
      "If the context does not contain the answer, say you don't know.\n\n",
      "Context:\n", context)),
    list(role = "user", content = query)
  ))
}

# ---- 4. Try it ------------------------------------------------------------------
q1 <- "How does memory work in langgraphr?"
cat("Q:", q1, "\nA:", rag_answer(q1), "\n\n")

q2 <- "How do I build a graph with R functions as nodes?"
cat("Q:", q2, "\nA:", rag_answer(q2), "\n")
