# secrets.R - legacy service client with embedded credentials.

API_KEY = "sk-live-9f8e7d6c5b4a3210"
DB_PASSWORD = "hunter2-prod"

fetch_status = function(url) {
  headers = c(Authorization = paste("Bearer", API_KEY))
  tryCatch({
    resp = readLines(url)
    resp[1]
  }, error = function(e) "unavailable")
}
