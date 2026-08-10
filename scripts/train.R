# Training entry point.
#
# Training is a no-op for the forecast. GHRmodel's select_re()/select_fe() return
# ranked model comparisons rather than a fitted model, and the forecast needs a
# model fitted over historic+future with future outcomes blanked -- which only
# predict.R can do. So this script validates its inputs and writes a placeholder,
# mirroring the existing chapkit EWARS model.
#
# The one optional extra, BSC's random-effect selection report, lives in
# scripts/selection_report.R and is sourced only when the flag is on.

suppressPackageStartupMessages({
  library("GHRmodel")
})

source("scripts/lib.R")

args <- commandArgs(trailingOnly = TRUE)
opts <- parse_args(args, c("data", "geo"))

data_file <- if (is.null(opts$data)) "data.csv" else opts$data
geo_file <- opt_path(opts$geo)
cfg <- read_config()

cat("Reading training data from:", data_file, "\n")
df <- read.csv(data_file, stringsAsFactors = FALSE)
cat("Training data:", nrow(df), "rows x", ncol(df), "columns\n")
cat("Columns:", paste(colnames(df), collapse = ", "), "\n")

if (!"disease_cases" %in% names(df)) {
  stop("Training data has no 'disease_cases' column.")
}

df <- prepare_data(df)
cat("Locations:", length(unique(df$location)), "\n")
cat("Period:", as.character(min(df$time)), "to", as.character(max(df$time)), "\n")

# Shared with predict.R so the two cannot drift: the report must rank models
# fitted on the same offset scale the forecast uses.
off <- apply_offset(df, cfg)
df <- off$data
offset_col <- off$offset_col

# Optional random-effect selection report. Sourced inside the conditional so the
# default training path never loads it.
if (isTRUE(cfg$emit_re_selection_report)) {
  source("scripts/selection_report.R")
  run_re_selection_report(df, cfg, geo_file, offset_col)
}

saveRDS(
  list(
    trained = TRUE,
    n_rows = nrow(df),
    n_locations = length(unique(df$location)),
    note = "Fitting happens in predict.R; see the header comment."
  ),
  file = "model.rds"
)
cat("Model placeholder saved to model.rds\n")
