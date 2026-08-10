# Generates example_data/ from GHRmodel's own bundled dengue_MS + map_MS.
#
# Development tooling, not part of the service image. Run from the repo root to
# refresh the fixtures:
#   docker run --rm --platform linux/amd64 -v "$PWD":/work <image> \
#     Rscript tools/make_example_data.R
#
# Using BSC's own data keeps the example honest: real geometry, real counts,
# real seasonality. Renamed into CHAP's column convention (time_period,
# location, disease_cases, population).
#
# Note on covariates: dengue_MS carries tmin/tmax/pdsi and no precipitation, so
# the example uses mean_temperature (the tmin/tmax midpoint) and pdsi rather
# than relabelling a drought index as "rainfall".

suppressPackageStartupMessages({
  library("GHRmodel")
  library("sf")
})

data(dengue_MS)
data(map_MS)

df <- as.data.frame(dengue_MS)
df <- df[stats::complete.cases(df[, c("dengue_cases", "population", "tmin", "tmax", "pdsi")]), ]

out <- data.frame(
  time_period = format(df$date, "%Y-%m"),
  location = as.character(df$micro_code),
  disease_cases = as.integer(df$dengue_cases),
  population = df$population,
  mean_temperature = (df$tmin + df$tmax) / 2,
  pdsi = df$pdsi,
  stringsAsFactors = FALSE
)
out <- out[order(out$location, out$time_period), ]

# Hold out the final 3 months as the forecast horizon.
horizon <- 3
periods <- sort(unique(out$time_period))
future_periods <- utils::tail(periods, horizon)
is_future <- out$time_period %in% future_periods

training <- out[!is_future, ]
future <- out[is_future, ]

# CHAP supplies future covariates but not future outcomes.
future$disease_cases <- NA

dir.create("example_data", showWarnings = FALSE)
write.csv(training, "example_data/training_data.csv", row.names = FALSE)
write.csv(future, "example_data/future_data.csv", row.names = FALSE)

# Geometry, keyed so that `code` matches the data's location values.
map_MS$code <- as.character(map_MS$code)
map_out <- map_MS[map_MS$code %in% unique(out$location), ]
if (file.exists("example_data/geo.json")) file.remove("example_data/geo.json")
sf::st_write(map_out, "example_data/geo.json", driver = "GeoJSON", quiet = TRUE)

cat("training:", nrow(training), "rows,", length(unique(training$location)), "locations\n")
cat("future:  ", nrow(future), "rows over", horizon, "periods\n")
cat("geo:     ", nrow(map_out), "features\n")
cat("periods: ", min(training$time_period), "to", max(training$time_period),
    "| forecast:", paste(future_periods, collapse = ", "), "\n")
