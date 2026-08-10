# Prediction entry point.
#
# Fits the single configured GHRmodel/INLA model over historic + future rows
# (future outcomes blanked to NA) and draws from the posterior predictive
# distribution for the future rows.
#
# The path through GHRmodel's exported API:
#   write_inla_formulas()  build one formula from the configured REs + covariates
#   as_GHRformulas()       returns a character vector; fit_models() needs the class
#   fit_models()           keep_inla_object=TRUE and config=TRUE are both required,
#                          sample_ppd() errors without them
#   sample_ppd()           draws for the future rows only, via pred_idx
#
# No GHRmodel source is modified.

suppressPackageStartupMessages({
  library("GHRmodel")
})

source("scripts/lib.R")

args <- commandArgs(trailingOnly = TRUE)
opts <- parse_args(args, c("historic", "future", "geo", "output"))

hist_file <- if (is.null(opts$historic)) "historic.csv" else opts$historic
future_file <- if (is.null(opts$future)) "future.csv" else opts$future
out_file <- if (is.null(opts$output)) "predictions.csv" else opts$output
geo_file <- opt_path(opts$geo)
cfg <- read_config()

cat("Historic:", hist_file, "\n")
cat("Future:  ", future_file, "\n")
cat("Geo:     ", if (is.null(geo_file)) "(none)" else geo_file, "\n")
cat("Output:  ", out_file, "\n")

historic <- read.csv(hist_file, stringsAsFactors = FALSE)
future <- read.csv(future_file, stringsAsFactors = FALSE)

# ---------------------------------------------------------------------------
# Combine
# ---------------------------------------------------------------------------

# INLA predicts by fitting over rows whose outcome is NA. Blank the future
# outcomes and mark which rows we will draw for.
if (!"disease_cases" %in% names(historic)) {
  stop("Historic data has no 'disease_cases' column; there is nothing to fit.")
}
future$disease_cases <- NA_real_

shared <- intersect(names(historic), names(future))
if (!"time_period" %in% shared || !"location" %in% shared) {
  stop("historic and future must share 'time_period' and 'location' columns.")
}
combined <- rbind(historic[, shared, drop = FALSE], future[, shared, drop = FALSE])
combined$.is_future <- c(rep(FALSE, nrow(historic)), rep(TRUE, nrow(future)))

combined <- prepare_data(combined)
is_future <- combined$.is_future

# One row per location-period. Overlap between historic and future, or repeats
# within either, would put the same time point in the series twice: the rolling
# and lag helpers would consume it, and the duplicated periods would silently
# distort the fit.
key <- paste(combined$location, combined$time_period, sep = "@")
if (anyDuplicated(key)) {
  dups <- unique(key[duplicated(key)])
  stop(
    length(dups), " location-period combination(s) appear more than once ",
    "across historic and future: ",
    paste(utils::head(dups, 5), collapse = ", "),
    if (length(dups) > 5) ", ..." else "", "\n",
    "  historic and future must not overlap."
  )
}

# Per block: each series must be internally consecutive (see assert_regular_periods).
# The historic/future seam is intentionally left free.
assert_regular_periods(combined[!is_future, , drop = FALSE])
assert_regular_periods(combined[is_future, , drop = FALSE])

cat("Combined:", nrow(combined), "rows;", sum(is_future), "to forecast across",
    length(unique(combined$location[is_future])), "locations\n")

# Shared with train.R so the two cannot drift. BSC's pipeline.R: "Make sure
# population is divided by a constant (e.g. 10,000) to improve convergence" --
# raw population produces NAN/INF in the log-likelihood on some windows.
off <- apply_offset(combined, cfg)
combined <- off$data
offset_col <- off$offset_col

# ---------------------------------------------------------------------------
# Geometry and priors
# ---------------------------------------------------------------------------

# Both are bound as plain names in this environment on purpose: GHRmodel writes
# `graph = g` and `hyper = prec1` literally into the formula string, and INLA
# resolves them from the environment at fit time.
g <- build_graph(geo_file, combined$location)
# The forecast fits one configuration, so only the first prior is used -- but
# bind_priors() creates prec1..precN so the names line up with what the
# selection report searched over.
prior_names <- bind_priors(cfg$priors)
cat("Priors bound:", paste(prior_names, collapse = ", "),
    "| forecast uses", prior_names[1], "\n")

if (is.null(g)) {
  cat("Fitting without a spatial random effect.\n")
}

# ---------------------------------------------------------------------------
# Covariates
# ---------------------------------------------------------------------------

covariates <- unlist(cfg$additional_continuous_covariates)
covariates <- covariates[nzchar(covariates)]
missing_cov <- setdiff(covariates, names(combined))
if (length(missing_cov)) {
  # Fail rather than drop. Silently fitting without a covariate the user
  # explicitly configured yields a materially different model while reporting
  # success -- the same failure class as a silently disabled spatial effect.
  stop(
    "Configured covariate(s) not present in the data: ",
    paste(missing_cov, collapse = ", "), "\n",
    "  columns supplied: ",
    paste(setdiff(shared, c("time_period", "location", "disease_cases")), collapse = ", "), "\n",
    "  Set additional_continuous_covariates to match your data."
  )
}

cov_terms <- character(0)
if (length(covariates)) {
  derived <- derive_covariates(
    data = combined,
    covariates = covariates,
    roll_mean = parse_spec(cfg$roll_mean),
    roll_sum = parse_spec(cfg$roll_sum),
    lag = parse_spec(cfg$lag),
    standardize = cfg$standardize,
    time_col = "time",
    area_col = "location"
  )
  combined <- derived$data
  cov_terms <- derived$covariates
  cat("Derived covariate terms:", paste(cov_terms, collapse = ", "), "\n")
}

# Non-linear effects, via GHRmodel's cov_nl(). Applied to the derived terms
# whose base name matches, so "mean_temperature:8" covers mean_temperature.rmean3.l1.
nl_spec <- parse_spec(cfg$nl)
validate_nl_spec(nl_spec)
if (!is.null(nl_spec) && length(cov_terms)) {
  for (cov in names(nl_spec)) {
    n <- nl_spec[[cov]][1]  # validate_nl_spec() guarantees exactly one

    # Scope to THIS covariate's terms (see cov_terms_for): cov_nl() selects by
    # prefix, so passing the full list would also convert a longer covariate's
    # terms, and the replacement below would silently make it non-linear.
    this_terms <- cov_terms_for(cov_terms, cov)
    nl_terms <- try(unlist(GHRmodel::cov_nl(this_terms, pattern = cov, n = n)), silent = TRUE)
    if (inherits(nl_terms, "try-error") || !length(nl_terms)) {
      # Continuing here would fit a LINEAR term for a covariate the user asked
      # to be non-linear, and report success. Fail instead.
      stop(
        "Could not build a non-linear effect for '", cov, "' (n=", n, ").\n",
        "  candidate terms: ", paste(cov_terms, collapse = ", "), "\n",
        "  Check that 'nl' names a covariate present in ",
        "additional_continuous_covariates.",
        if (inherits(nl_terms, "try-error")) {
          paste0("\n  cov_nl() said: ", trimws(as.character(nl_terms)))
        } else {
          ""
        }
      )
    }
    # Swap this covariate's linear terms for their non-linear form. setdiff
    # removes exactly the terms just handed to cov_nl(), so nothing else moves.
    cov_terms <- c(setdiff(cov_terms, this_terms), nl_terms)
    cat("Non-linear effect (n=", n, ") applied to '", cov, "'\n", sep = "")
  }
  cov_terms <- unique(cov_terms)
}

# Lagging introduces NA at the head of each series. Drop those rows, but never
# a row we need to forecast.
if (length(cov_terms)) {
  complete <- stats::complete.cases(combined[, cov_terms, drop = FALSE])

  # Only *leading* rows should be incomplete -- that is the lag structure doing
  # its job. An incomplete row after the series has started means the input data
  # has a hole, and dropping it would splice the series back together across a
  # gap without saying so.
  gappy <- character(0)
  for (loc in unique(combined$location[!is_future])) {
    rows <- which(combined$location == loc & !is_future)
    incomplete <- !complete[rows]
    first_ok <- match(FALSE, incomplete)
    if (is.na(first_ok)) next  # nothing complete: entirely leading
    if (any(incomplete[first_ok:length(incomplete)])) gappy <- c(gappy, loc)
  }
  if (length(gappy)) {
    stop(
      "Missing covariate values mid-series for location(s): ",
      paste(utils::head(gappy, 5), collapse = ", "),
      if (length(gappy) > 5) ", ..." else "", "\n",
      "  Only the leading rows should be incomplete, from the lag/rolling ",
      "windows. A gap later in the series indicates missing input data; ",
      "dropping it would join the series across the hole."
    )
  }

  drop <- !complete & !is_future
  if (any(drop)) {
    cat("Dropping", sum(drop), "leading rows made incomplete by the lag structure.\n")
    combined <- combined[!drop, , drop = FALSE]
    is_future <- is_future[!drop]
  }
  if (any(!stats::complete.cases(combined[, cov_terms, drop = FALSE]) & is_future)) {
    stop(
      "Forecast rows have missing covariate values. Supply future covariate ",
      "data, or reduce the lag/rolling windows."
    )
  }
}

# ---------------------------------------------------------------------------
# Formula
# ---------------------------------------------------------------------------

re_specs <- build_re_specs(cfg, has_graph = !is.null(g))
if (!length(re_specs) && !length(cov_terms)) {
  stop("Model has no random effects and no covariates; nothing to fit.")
}

# A single-element list of a character vector yields exactly one formula
# containing all the terms. baseline = TRUE is required when there are no
# covariates, since that is what emits the random-effects-only formula.
formula_args <- list(
  outcome = "disease_cases",
  covariates = if (length(cov_terms)) list(cov_terms) else NULL,
  baseline = length(cov_terms) == 0
)
for (i in seq_along(re_specs)) {
  formula_args[[paste0("re", i)]] <- re_specs[[i]]
}

formulas <- do.call(GHRmodel::write_inla_formulas, formula_args)
if (!length(formulas)) {
  stop("write_inla_formulas() produced no formulas for this configuration.")
}
cat("\nModel formula:\n  ", formulas[1], "\n\n", sep = "")

formulas <- GHRmodel::as_GHRformulas(formulas)

# ---------------------------------------------------------------------------
# Fit and sample
# ---------------------------------------------------------------------------

models <- GHRmodel::fit_models(
  formulas = formulas,
  data = combined,
  family = validate_family(cfg$family),
  name = "chap",
  offset = offset_col,
  control_compute = list(config = TRUE, vcov = FALSE),
  keep_inla_object = TRUE,
  nthreads = cfg$nthreads
)

# fit_models() catches INLA errors and only message()s "model failed to run.
# Skipping Model N", so a failed fit surfaces here as an empty result rather
# than an exception. Without this check, mod_id becomes NA and sample_ppd()
# fails with "missing value where TRUE/FALSE needed".
if (is.null(models$mod_gof) || !nrow(models$mod_gof) ||
    all(vapply(models$inla_objects, is.null, logical(1)))) {
  stop(
    "INLA failed to fit the model; see the 'model failed to run' message above.\n",
    "  Common causes: an offset on the wrong scale (see offset_scale), ",
    "collinear covariates, or too little data for the random effects requested."
  )
}

mod_id <- models$mod_gof[["model_id"]][1]
cat("Sampling", cfg$n_samples, "draws from", mod_id, "\n")

ppd <- GHRmodel::sample_ppd(
  models = models,
  mod_id = mod_id,
  nsamples = cfg$n_samples,
  nthreads = cfg$nthreads,
  pred_idx = which(is_future)
)

if (is.null(dim(ppd)) || nrow(ppd) != sum(is_future)) {
  stop("sample_ppd() returned ", NROW(ppd), " rows; expected ", sum(is_future), ".")
}

# ---------------------------------------------------------------------------
# CHAP-shaped output
# ---------------------------------------------------------------------------

out <- data.frame(
  time_period = as.character(combined$time_period[is_future]),
  location = as.character(combined$location[is_future]),
  stringsAsFactors = FALSE
)
out <- cbind(out, as.data.frame(ppd))
colnames(out) <- c("time_period", "location", paste0("sample_", 0:(ncol(ppd) - 1)))

write.csv(out, out_file, row.names = FALSE)
cat("Wrote", nrow(out), "rows x", ncol(ppd), "samples to", out_file, "\n")
