# tools.R - the seven tools the ReAct agent can call.
#
# Each function returns a MODEL-FRIENDLY string: the hidden server sends
# these values back to the model as tool results, so they must read well
# as plain text. The Shiny front end shows the same text inside the tool
# activity card (see utils.R::format_tool_result).
#
# All network tools use free, key-less public APIs.

# ---- live data tools -------------------------------------------------------

# get_weather(city) - Open-Meteo: geocode the city name, then fetch the
# current conditions at those coordinates.
get_weather <- function(city) {
  # Step 1: geocode the city to latitude/longitude.
  geo <- httr::GET(
    "https://geocoding-api.open-meteo.com/v1/search",
    query = list(name = city, count = 1, language = "en", format = "json"),
    httr::timeout(15))
  geo <- httr::content(geo, as = "parsed")
  # No match: tell the model clearly so it can ask the user again.
  if (length(first_or(geo$results, list())) == 0L) {
    return(sprintf("No city named '%s' was found.", city))
  }
  hit <- geo$results[[1]]
  # Step 2: current conditions at those coordinates.
  wx <- httr::GET(
    "https://api.open-meteo.com/v1/forecast",
    query = list(
      latitude = hit$latitude,
      longitude = hit$longitude,
      current = "temperature_2m,relative_humidity_2m,weather_code"),
    httr::timeout(15))
  cur <- first_or(httr::content(wx, as = "parsed")$current, list())
  sprintf(paste0("Current weather in %s, %s:\n- temperature: %.1f C\n",
                 "- condition: %s\n- humidity: %.0f%%"),
          first_or(hit$name, city), first_or(hit$country, ""),
          first_or(cur$temperature_2m, NA_real_),
          weather_code_text(first_or(cur$weather_code, NA)),
          first_or(cur$relative_humidity_2m, NA_real_))
}

# weather_code_text(code) - maps Open-Meteo's numeric WMO weather codes to
# short human descriptions.
weather_code_text <- function(code) {
  lookup <- c(
    "0" = "clear sky", "1" = "mainly clear", "2" = "partly cloudy",
    "3" = "overcast", "45" = "fog", "48" = "depositing rime fog",
    "51" = "light drizzle", "53" = "moderate drizzle", "55" = "dense drizzle",
    "61" = "slight rain", "63" = "moderate rain", "65" = "heavy rain",
    "66" = "freezing rain", "67" = "heavy freezing rain",
    "71" = "slight snowfall", "73" = "moderate snowfall", "75" = "heavy snowfall",
    "80" = "slight rain showers", "81" = "moderate rain showers",
    "82" = "violent rain showers",
    "85" = "slight snow showers", "86" = "heavy snow showers",
    "95" = "thunderstorm", "96" = "thunderstorm with hail",
    "99" = "severe thunderstorm with hail")
  key <- as.character(code)
  if (key %in% names(lookup)) unname(lookup[key]) else sprintf("weather code %s", key)
}

# get_exchange_rate(from, to, amount) - Frankfurter (European Central Bank
# reference rates, no key). from/to are currency codes such as USD, EUR.
get_exchange_rate <- function(from, to, amount = 1) {
  amount <- suppressWarnings(as.numeric(amount))
  if (is.na(amount)) amount <- 1
  from <- toupper(as.character(from))
  to <- toupper(as.character(to))
  r <- httr::GET("https://api.frankfurter.app/latest",
                 query = list(from = from, to = to), httr::timeout(15))
  r <- httr::content(r, as = "parsed")
  rate <- first_or(r$rates[[first_or(to, 1)]], NULL)
  if (is.null(rate)) {
    return(sprintf("Could not convert %s to %s - check the currency codes.",
                   from, to))
  }
  sprintf(paste0("%.2f %s = %.2f %s\n(live rate: 1 %s = %s %s, ",
                 "ECB reference of %s)"),
          amount, from, amount * as.numeric(rate), to,
          from, format(as.numeric(rate)), first_or(r$date, "latest"))
}

# get_country_info(country) - REST Countries: population, capital, region
# and languages for any country name.
get_country_info <- function(country) {
  r <- httr::GET(
    sprintf("https://restcountries.com/v3.1/name/%s",
            utils::URLencode(as.character(country))),
    query = list(fields = "name,capital,population,region,languages"),
    httr::timeout(15))
  hits <- httr::content(r, as = "parsed")
  if (!is.list(hits) || length(hits) == 0L) {
    return(sprintf("No country named '%s' was found.", country))
  }
  hit <- hits[[1]]
  langs <- first_or(names(first_or(hit$languages, list())), "")
  sprintf(paste0("%s:\n- capital: %s\n- population: %s\n- region: %s\n",
                 "- languages: %s"),
          first_or(hit$name$common, country),
          paste(first_or(hit$capital, "n/a"), collapse = ", "),
          format(first_or(hit$population, 0), big.mark = ",",
                 scientific = FALSE),
          first_or(hit$region, "n/a"),
          if (nzchar(langs)) paste(langs, collapse = ", ") else "n/a")
}

# ---- file reading tools ----------------------------------------------------

# resolve_upload(filepath, upload_dir) - find a file the model referred to:
# absolute/relative paths that exist are used as-is; bare file names are
# looked up in the session upload folder.
resolve_upload <- function(filepath, upload_dir = NULL) {
  filepath <- as.character(filepath)
  if (file.exists(filepath)) return(normalizePath(filepath, winslash = "/"))
  if (!is.null(upload_dir)) {
    candidate <- file.path(upload_dir, basename(filepath))
    if (file.exists(candidate)) {
      return(normalizePath(candidate, winslash = "/"))
    }
  }
  stop(sprintf("File '%s' not found. Use list_uploaded_files to see what ",
               "the user has uploaded.", filepath), call. = FALSE)
}

# read_data_df(filepath, upload_dir) - internal: read a CSV/Excel file into
# a data frame, choosing the reader by file extension.
read_data_df <- function(filepath, upload_dir = NULL) {
  fp <- resolve_upload(filepath, upload_dir)
  ext <- tolower(tools::file_ext(fp))
  if (ext == "csv") {
    readr::read_csv(fp, show_col_types = FALSE, progress = FALSE)
  } else if (ext %in% c("xlsx", "xls")) {
    readxl::read_excel(fp)
  } else {
    stop(sprintf("'%s' is not a CSV or Excel file - use read_text_file ",
                 "for text and PDF files.", basename(fp)), call. = FALSE)
  }
}

# read_data_file(filepath, upload_dir) - returns a list: `text` is the
# model-facing summary, `df` is the parsed data (kept by the agent wrapper
# so summarize_dataframe can analyze it later).
read_data_file <- function(filepath, upload_dir = NULL) {
  fp <- resolve_upload(filepath, upload_dir)
  df <- read_data_df(fp, upload_dir)
  text <- sprintf(paste0("File: %s\nRows: %d\nColumns: %d\n",
                         "Column names: %s\n\nFirst 5 rows:\n%s"),
                  basename(fp), nrow(df), ncol(df),
                  paste(names(df), collapse = ", "),
                  paste(utils::capture.output(print(head(df, 5))),
                        collapse = "\n"))
  list(text = text, df = df)
}

# read_text_file(filepath, upload_dir) - plain text files via readLines,
# PDF files via pdftools; long contents are truncated to 2000 characters.
read_text_file <- function(filepath, upload_dir = NULL) {
  fp <- resolve_upload(filepath, upload_dir)
  ext <- tolower(tools::file_ext(fp))
  text <- if (ext == "pdf") {
    pages <- pdftools::pdf_text(fp)
    paste(unlist(pages), collapse = "\n\n--- page break ---\n\n")
  } else if (ext %in% c("txt", "md", "log")) {
    paste(readLines(fp, warn = FALSE), collapse = "\n")
  } else {
    stop(sprintf("'%s' is not a text or PDF file - use read_data_file for ",
                 "CSV and Excel files.", basename(fp)), call. = FALSE)
  }
  if (nchar(text) > 2000) {
    text <- paste0(substr(text, 1, 2000),
                   "\n\n... (truncated at 2000 characters)")
  }
  sprintf("Contents of %s:\n\n%s", basename(fp), text)
}

# list_uploaded_files(upload_dir) - names from the session upload manifest.
list_uploaded_files <- function(upload_dir) {
  manifest <- file.path(upload_dir, "upload_manifest.json")
  if (!file.exists(manifest)) {
    return("No files have been uploaded in this session.")
  }
  names <- jsonlite::fromJSON(manifest, simplifyVector = TRUE)
  if (length(names) == 0L) {
    return("No files have been uploaded in this session.")
  }
  paste0("Files uploaded this session:\n",
         paste(paste0("- ", names), collapse = "\n"))
}

# summarize_dataframe(data, upload_dir, last_df) - summary() output plus
# per-column details. `data` may be a data frame, a filepath, or NULL to
# use the most recently loaded file (last_df, kept by the agent wrapper).
summarize_dataframe <- function(data = NULL, upload_dir = NULL,
                                last_df = NULL) {
  df <- if (is.null(data)) {
    last_df
  } else if (is.data.frame(data)) {
    data
  } else if (is.character(data)) {
    read_data_df(data, upload_dir)
  } else {
    NULL
  }
  if (is.null(df) || !is.data.frame(df)) {
    return(paste0("No data frame available yet. Use read_data_file to ",
                  "load one first."))
  }
  col_details <- paste(vapply(names(df), function(nm) {
    sprintf("- %s (%s)", nm, class(df[[nm]])[1])
  }, character(1)), collapse = "\n")
  sprintf(paste0("Data frame: %d rows x %d columns\n\nsummary():\n%s\n\n",
                 "Column details:\n%s"),
          nrow(df), ncol(df),
          paste(utils::capture.output(summary(df)), collapse = "\n"),
          col_details)
}
