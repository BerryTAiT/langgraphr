# tools.R - Data Detective tools
#
# Pure-R tools for data analysis and visualization.
# Uses ggplot2 if available, otherwise falls back to base R graphics.
# All plots saved as PNG to www/plots/ for web rendering.

# ---- state ----------------------------------------------------------------

detective_state <- new.env(parent = emptyenv())
detective_state$dataset <- NULL
detective_state$dataset_name <- NULL
detective_state$plot_dir <- NULL
detective_state$plot_count <- 0
detective_state$plots_created <- list()

# ---- helpers --------------------------------------------------------------

ensure_plot_dir <- function() {
  if (is.null(detective_state$plot_dir)) {
    # Find the www/ directory relative to the app
    www <- file.path(dirname(detective_state$app_dir %||% "."), "www")
    if (!dir.exists(www)) www <- "www"
    plot_dir <- file.path(www, "plots")
    if (!dir.exists(plot_dir)) {
      try(dir.create(plot_dir, recursive = TRUE), silent = TRUE)
    }
    detective_state$plot_dir <- plot_dir
  }
  detective_state$plot_dir
}

has_ggplot <- function() {
  requireNamespace("ggplot2", quietly = TRUE)
}

has_DT <- function() {
  requireNamespace("DT", quietly = TRUE)
}

next_plot_id <- function() {
  detective_state$plot_count <- detective_state$plot_count + 1
  sprintf("plot_%03d", detective_state$plot_count)
}

# ---- data loading ---------------------------------------------------------

load_dataset <- function(name = "iris") {
  name <- as.character(name)

  if (file.exists(name) && grepl("\\.csv$", name, ignore.case = TRUE)) {
    df <- tryCatch(
      read.csv(name, stringsAsFactors = FALSE),
      error = function(e) stop(sprintf("Failed to read CSV: %s", conditionMessage(e)))
    )
    label <- basename(name)
  } else if (file.exists(name) && grepl("\\.(tsv|txt)$", name, ignore.case = TRUE)) {
    df <- tryCatch(
      read.delim(name, stringsAsFactors = FALSE),
      error = function(e) stop(sprintf("Failed to read file: %s", conditionMessage(e)))
    )
    label <- basename(name)
  } else {
    key <- tolower(name)
    df <- switch(key,
      iris = iris,
      mtcars = mtcars,
      airquality = airquality,
      stop("Unknown dataset. Use 'iris', 'mtcars', 'airquality', or a CSV file path.")
    )
    label <- key
  }

  detective_state$dataset <- df
  detective_state$dataset_name <- label
  detective_state$plot_count <- 0
  detective_state$plots_created <- list()

  sprintf(
    "Loaded dataset '%s': %d rows, %d columns\nColumns: %s\n\nFirst 5 rows:\n%s",
    label, nrow(df), ncol(df),
    paste(names(df), collapse = ", "),
    paste(capture.output(print(head(df, 5))), collapse = "\n")
  )
}

load_data_frame <- function(df, name = "uploaded_data") {
  detective_state$dataset <- df
  detective_state$dataset_name <- name
  detective_state$plot_count <- 0
  detective_state$plots_created <- list()
  invisible(NULL)
}

# ---- analysis tools -------------------------------------------------------

summary_stats <- function(columns = NULL) {
  df <- detective_state$dataset
  if (is.null(df)) return("No dataset loaded. Use load_dataset first.")

  if (!is.null(columns)) {
    if (is.list(columns)) columns <- unlist(columns)
    columns <- as.character(columns)
  }

  nums <- names(df)[sapply(df, is.numeric)]
  if (!is.null(columns) && length(columns) > 0) nums <- intersect(columns, nums)
  if (length(nums) == 0) return("No numeric columns found.")

  lines <- character(0)
  for (col in nums) {
    x <- df[[col]]
    lines <- c(lines, sprintf(
      "%s: mean=%.2f, median=%.2f, sd=%.2f, min=%.2f, max=%.2f, NAs=%d, n=%d",
      col,
      round(mean(x, na.rm = TRUE), 2),
      round(median(x, na.rm = TRUE), 2),
      round(sd(x, na.rm = TRUE), 2),
      round(min(x, na.rm = TRUE), 2),
      round(max(x, na.rm = TRUE), 2),
      sum(is.na(x)),
      sum(!is.na(x))
    ))
  }
  paste("Summary statistics:\n", paste(lines, collapse = "\n"))
}

detect_outliers <- function(column) {
  df <- detective_state$dataset
  if (is.null(df)) return("No dataset loaded.")
  if (!column %in% names(df)) return(sprintf("Column '%s' not found.", column))

  x <- df[[column]]
  if (!is.numeric(x)) return(sprintf("Column '%s' is not numeric.", column))

  q1 <- quantile(x, 0.25, na.rm = TRUE)
  q3 <- quantile(x, 0.75, na.rm = TRUE)
  iqr <- q3 - q1
  lower <- q1 - 1.5 * iqr
  upper <- q3 + 1.5 * iqr

  outliers <- which(x < lower | x > upper)
  if (length(outliers) == 0) {
    return(sprintf("No outliers in '%s' (bounds: [%.2f, %.2f]).", column, lower, upper))
  }
  sprintf("Found %d outliers in '%s' (bounds: [%.2f, %.2f]). Values: %s",
    length(outliers), column, lower, upper,
    paste(sprintf("%.2f", x[outliers]), collapse = ", "))
}

correlation_matrix <- function(columns = NULL) {
  df <- detective_state$dataset
  if (is.null(df)) return("No dataset loaded.")

  if (!is.null(columns)) {
    if (is.list(columns)) columns <- unlist(columns)
    columns <- as.character(columns)
  }

  nums <- names(df)[sapply(df, is.numeric)]
  if (!is.null(columns) && length(columns) > 0) nums <- intersect(columns, nums)
  if (length(nums) < 2) return("Need at least 2 numeric columns.")

  cors <- cor(df[, nums], use = "complete.obs")
  lines <- character(0)
  for (i in seq_along(nums)) {
    for (j in (i + 1):length(nums)) {
      if (j > length(nums)) break
      r <- round(cors[i, j], 3)
      strength <- if (abs(r) > 0.7) "strong" else if (abs(r) > 0.4) "moderate" else "weak"
      direction <- if (r > 0) "positive" else "negative"
      lines <- c(lines, sprintf("  %s vs %s: r=%.3f (%s %s)", nums[i], nums[j], r, strength, direction))
    }
  }
  paste("Correlation matrix:\n", paste(lines, collapse = "\n"))
}

column_info <- function() {
  df <- detective_state$dataset
  if (is.null(df)) return("No dataset loaded.")

  lines <- character(0)
  for (col in names(df)) {
    x <- df[[col]]
    uniq <- length(unique(x))
    nas <- sum(is.na(x))
    lines <- c(lines, sprintf("  %s: type=%s, unique=%d, NAs=%d, n=%d",
      col, class(x)[1], uniq, nas, length(x)))
  }
  paste("Column info:\n", paste(lines, collapse = "\n"))
}

frequency_table <- function(column) {
  df <- detective_state$dataset
  if (is.null(df)) return("No dataset loaded.")
  if (!column %in% names(df)) return(sprintf("Column '%s' not found.", column))

  x <- df[[column]]
  tab <- table(x)
  pct <- round(prop.table(tab) * 100, 1)
  lines <- sprintf("  %s: %d (%.1f%%)", names(tab), as.integer(tab), pct)
  sprintf("Frequency table for '%s':\n%s", column, paste(lines, collapse = "\n"))
}

group_comparison <- function(numeric_col, group_col) {
  df <- detective_state$dataset
  if (is.null(df)) return("No dataset loaded.")
  if (!numeric_col %in% names(df) || !group_col %in% names(df))
    return(sprintf("Column(s) not found. Available: %s", paste(names(df), collapse = ", ")))

  x <- df[[numeric_col]]
  g <- df[[group_col]]
  if (!is.numeric(x)) return(sprintf("'%s' is not numeric.", numeric_col))

  groups <- split(x, g)
  lines <- sapply(names(groups), function(grp) {
    vals <- groups[[grp]]
    sprintf("  %s: mean=%.2f, sd=%.2f, n=%d",
      grp, round(mean(vals, na.rm = TRUE), 2),
      round(sd(vals, na.rm = TRUE), 2),
      sum(!is.na(vals)))
  })
  sprintf("Group comparison: %s by %s\n%s",
    numeric_col, group_col, paste(lines, collapse = "\n"))
}

# ---- visualization tools --------------------------------------------------

create_plot <- function(type = "bar", x = NULL, y = NULL,
                         color = NULL, bins = 30, title = NULL,
                         subtitle = NULL, caption = NULL) {
  df <- detective_state$dataset
  if (is.null(df)) return("No dataset loaded. Use load_dataset first.")

  type <- tolower(as.character(type))
  valid_types <- c("bar", "line", "scatter", "histogram", "box", "pie", "area", "heatmap")
  if (!type %in% valid_types) {
    return(sprintf("Invalid plot type '%s'. Valid: %s", type, paste(valid_types, collapse = ", ")))
  }

  plot_id <- next_plot_id()
  plot_file <- file.path(ensure_plot_dir(), paste0(plot_id, ".png"))

  # Build title
  ttl <- title %||% paste0(toupper(type), " Plot")
  if (is.null(title)) {
    if (!is.null(x) && !is.null(y)) ttl <- paste(y, "vs", x)
    else if (!is.null(x)) ttl <- x
    else ttl <- paste0(type, " of data")
  }

  tryCatch({
    if (has_ggplot()) {
      p <- ggplot2::ggplot(df)

      if (type == "bar") {
        if (is.null(x)) stop("Bar chart requires 'x' (category column)")
        if (is.null(y)) {
          p <- p + ggplot2::geom_bar(ggplot2::aes_string(x = x, fill = color %||% x))
        } else {
          p <- p + ggplot2::geom_col(ggplot2::aes_string(x = x, y = y, fill = color))
        }
      } else if (type == "line") {
        if (is.null(x) || is.null(y)) stop("Line chart requires 'x' and 'y'")
        p <- p + ggplot2::geom_line(ggplot2::aes_string(x = x, y = y, color = color, group = color %||% "1"))
      } else if (type == "scatter") {
        if (is.null(x) || is.null(y)) stop("Scatter plot requires 'x' and 'y'")
        p <- p + ggplot2::geom_point(ggplot2::aes_string(x = x, y = y, color = color), size = 2.5, alpha = 0.7)
      } else if (type == "histogram") {
        if (is.null(x)) stop("Histogram requires 'x' (numeric column)")
        p <- p + ggplot2::geom_histogram(ggplot2::aes_string(x = x, fill = color), bins = as.integer(bins))
      } else if (type == "box") {
        if (is.null(x)) stop("Box plot requires 'x' (numeric column)")
        if (is.null(color)) {
          p <- p + ggplot2::geom_boxplot(ggplot2::aes_string(y = x))
        } else {
          p <- p + ggplot2::geom_boxplot(ggplot2::aes_string(x = color, y = x, fill = color))
        }
      } else if (type == "pie") {
        if (is.null(x)) stop("Pie chart requires 'x' (category column)")
        tab <- as.data.frame(table(df[[x]]))
        names(tab) <- c("category", "count")
        p <- ggplot2::ggplot(tab, ggplot2::aes(x = "", y = count, fill = category)) +
          ggplot2::geom_col() +
          ggplot2::coord_polar("y")
      } else if (type == "area") {
        if (is.null(x) || is.null(y)) stop("Area chart requires 'x' and 'y'")
        p <- p + ggplot2::geom_area(ggplot2::aes_string(x = x, y = y, fill = color), alpha = 0.7)
      } else if (type == "heatmap") {
        nums <- names(df)[sapply(df, is.numeric)]
        if (length(nums) < 2) stop("Heatmap needs 2+ numeric columns")
        cor_mat <- cor(df[, nums], use = "complete.obs")
        melt_df <- as.data.frame(as.table(cor_mat))
        names(melt_df) <- c("Var1", "Var2", "value")
        p <- ggplot2::ggplot(melt_df, ggplot2::aes(Var1, Var2, fill = value)) +
          ggplot2::geom_tile() +
          ggplot2::geom_text(ggplot2::aes(label = sprintf("%.2f", value)), size = 3) +
          ggplot2::scale_fill_gradient2(low = "#6366f1", mid = "white", high = "#ef4444", midpoint = 0)
      }

      p <- p + ggplot2::labs(title = ttl, subtitle = subtitle, caption = caption, x = x, y = y) +
        ggplot2::theme_minimal(base_size = 13) +
        ggplot2::theme(
          plot.title = ggplot2::element_text(face = "bold", size = 15),
          plot.background = ggplot2::element_rect(fill = "white", color = NA),
          panel.background = ggplot2::element_rect(fill = "white"),
          legend.position = "bottom"
        )

      ggplot2::ggsave(plot_file, p, width = 8, height = 5, dpi = 150, bg = "white")

    } else {
      # Base R fallback
      png(plot_file, width = 800, height = 500, res = 150)
      par(mar = c(4, 4, 4, 2), bg = "white")

      if (type == "bar") {
        if (is.null(x)) stop("Bar chart requires 'x'")
        tab <- table(df[[x]])
        barplot(tab, main = ttl, col = "#4f46e5", las = 2, cex.names = 0.8)
      } else if (type == "line") {
        if (is.null(x) || is.null(y)) stop("Line requires 'x' and 'y'")
        plot(df[[x]], df[[y]], type = "l", main = ttl, xlab = x, ylab = y, col = "#4f46e5", lwd = 2)
      } else if (type == "scatter") {
        if (is.null(x) || is.null(y)) stop("Scatter requires 'x' and 'y'")
        plot(df[[x]], df[[y]], main = ttl, xlab = x, ylab = y, col = "#4f46e5", pch = 19, cex = 0.7)
      } else if (type == "histogram") {
        if (is.null(x)) stop("Histogram requires 'x'")
        hist(df[[x]], main = ttl, xlab = x, col = "#4f46e5", border = "white", breaks = as.integer(bins))
      } else if (type == "box") {
        if (is.null(x)) stop("Box plot requires 'x'")
        if (is.null(color)) {
          boxplot(df[[x]], main = ttl, col = "#4f46e5")
        } else {
          boxplot(df[[x]] ~ df[[color]], main = ttl, col = "#4f46e5", xlab = color, ylab = x)
        }
      } else if (type == "pie") {
        if (is.null(x)) stop("Pie requires 'x'")
        tab <- table(df[[x]])
        pie(tab, main = ttl, col = rainbow(length(tab)))
      } else if (type == "heatmap") {
        nums <- names(df)[sapply(df, is.numeric)]
        if (length(nums) < 2) stop("Heatmap needs 2+ numeric columns")
        cor_mat <- cor(df[, nums], use = "complete.obs")
        heatmap(cor_mat, main = ttl, col = colorRampPalette(c("#6366f1", "white", "#ef4444"))(25))
      }

      dev.off()
    }

    # Return reference for UI rendering
    detective_state$plots_created <- c(detective_state$plots_created, plot_id)

    sprintf("[PLOT:%s.png] Created %s plot: %s. Saved as %s.",
      plot_id, type, ttl, plot_id)

  }, error = function(e) {
    if (exists("dev.off")) try(dev.off(), silent = TRUE)
    sprintf("Error creating plot: %s", conditionMessage(e))
  })
}

create_table <- function(columns = NULL, rows = 10, title = NULL) {
  df <- detective_state$dataset
  if (is.null(df)) return("No dataset loaded.")

  if (!is.null(columns)) {
    if (is.list(columns)) columns <- unlist(columns)
    columns <- as.character(columns)
    df <- df[, columns[columns %in% names(df)], drop = FALSE]
  }

  n <- min(as.integer(rows), nrow(df))
  df_show <- head(df, n)

  # Build HTML table
  hdr <- paste0("<th>", names(df_show), "</th>", collapse = "")
  body_rows <- sapply(seq_len(nrow(df_show)), function(i) {
    cells <- sapply(df_show[i, ], function(v) {
      if (is.numeric(v)) sprintf("%.2f", v) else as.character(v)
    })
    paste0("<td>", cells, "</td>", collapse = "")
  })
  body <- paste0("<tr>", body_rows, "</tr>", collapse = "")

  table_id <- sprintf("table_%03d", detective_state$plot_count + 1)
  detective_state$plot_count <- detective_state$plot_count + 1

  ttl <- title %||% paste0("Table: ", detective_state$dataset_name %||% "data")

  sprintf("[TABLE:%s] %s\n%s rows x %s columns shown.",
    table_id, ttl, n, ncol(df_show))
}

create_dashboard <- function(specs) {
  df <- detective_state$dataset
  if (is.null(df)) return("No dataset loaded.")

  if (is.list(specs) && !is.data.frame(specs)) {
    # Multiple plot specs
    results <- character(0)
    for (spec in specs) {
      r <- create_plot(
        type = spec$type %||% "bar",
        x = spec$x, y = spec$y,
        color = spec$color,
        title = spec$title
      )
      results <- c(results, r)
    }
    sprintf("[DASHBOARD:%d] Created dashboard with %d plots.\n%s",
      length(specs), length(specs), paste(results, collapse = "\n"))
  } else {
    "Dashboard specs must be a list of plot configurations."
  }
}

# ---- tool registry --------------------------------------------------------

detective_tools <- function() {
  list(
    load_dataset = load_dataset,
    summary_stats = summary_stats,
    detect_outliers = detect_outliers,
    correlation_matrix = correlation_matrix,
    column_info = column_info,
    frequency_table = frequency_table,
    group_comparison = group_comparison,
    create_plot = create_plot,
    create_table = create_table,
    create_dashboard = create_dashboard
  )
}

detective_tool_descriptions <- function() {
  c(
    load_dataset = "Load a dataset. Args: name ('iris','mtcars','airquality' or CSV file path).",
    summary_stats = "Get summary statistics. Args: columns (optional array of column names).",
    detect_outliers = "Detect outliers via IQR. Args: column (numeric column name).",
    correlation_matrix = "Pairwise correlations. Args: columns (optional array of names).",
    column_info = "Column types, unique values, NAs. No args.",
    frequency_table = "Frequency table. Args: column (categorical column name).",
    group_comparison = "Compare numeric across groups. Args: numeric_col, group_col.",
    create_plot = "Create a visualization. Args: type ('bar','line','scatter','histogram','box','pie','area','heatmap'), x (column), y (column), color (column), bins (for histogram), title. Example: {\"type\":\"bar\",\"x\":\"Species\",\"y\":\"Sepal.Length\"}",
    create_table = "Show data as a table. Args: columns (optional array), rows (default 10), title.",
    create_dashboard = "Create multiple plots. Args: specs (array of {type,x,y,color,title} objects)."
  )
}
