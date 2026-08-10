# Shared helpers for the GHRmodel chapkit wrapper.
#
# Everything here is wrapper plumbing. No GHRmodel behaviour is reimplemented
# or altered -- the model itself is driven entirely through its exported API
# (write_inla_formulas, as_GHRformulas, fit_models, sample_ppd, select_re,
# select_report).

suppressPackageStartupMessages({
  library("yaml")
})

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------

#' Parse `--flag value` pairs from the command line.
#'
#' Defensive about empty values: chapkit substitutes `{geo_file}` with an empty
#' string when no geometry is supplied, so `--geo {geo_file}` collapses to a
#' bare `--geo` after shell word-splitting. Without the `--` guard below, the
#' following flag would be consumed as geo's value.
parse_args <- function(args, flags) {
  out <- setNames(vector("list", length(flags)), flags)
  for (i in seq_along(args)) {
    flag <- sub("^--", "", args[i])
    if (!grepl("^--", args[i]) || !(flag %in% flags)) next
    if (i < length(args) && !grepl("^--", args[i + 1])) {
      out[[flag]] <- args[i + 1]
    }
  }
  out
}

#' Treat empty strings and missing files as "not supplied".
opt_path <- function(p) {
  if (is.null(p) || !nzchar(p) || !file.exists(p)) NULL else p
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

read_config <- function(path = "config.yml") {
  cfg <- if (file.exists(path)) yaml.load_file(path) else list()
  # Defaults mirror GHRModelConfig in main.py so the scripts stay runnable
  # standalone (outside chapkit) for debugging.
  defaults <- list(
    prediction_periods = 3,
    additional_continuous_covariates = list("rainfall", "mean_temperature"),
    re_spatial = "bym2",
    re_seasonal = "rw1",
    re_interannual = "iid",
    priors = "0.5:0.01",
    roll_mean = "mean_temperature:3",
    roll_sum = "rainfall:3",
    lag = "mean_temperature:1;rainfall:1",
    nl = "",
    standardize = TRUE,
    family = "nbinomial",
    offset = "population",
    offset_scale = 10000,
    n_samples = 1000,
    nthreads = 4,
    emit_re_selection_report = FALSE,
    report_re_spatial = "bym2",
    report_re_seasonal = "rw1,rw2",
    report_re_interannual = "iid,rw1,rw2"
  )
  for (k in names(defaults)) {
    if (is.null(cfg[[k]])) cfg[[k]] <- defaults[[k]]
  }
  cfg
}

#' Parse the string encoding for GHRmodel's nested list parameters.
#'
#' GHRmodel takes named lists of numeric vectors, e.g.
#'   list(mean_temperature = c(1, 3, 6), rainfall = c(1, 3))
#' which flat config fields cannot express, so they are encoded as a string:
#'   "mean_temperature:1,3,6;rainfall:1,3"
#' Returns NULL for an empty string, so it can be passed straight through to
#' arguments that default to NULL.
parse_spec <- function(s) {
  if (is.null(s) || !nzchar(trimws(s))) return(NULL)
  parts <- strsplit(trimws(s), ";", fixed = TRUE)[[1]]
  parts <- parts[nzchar(trimws(parts))]
  if (!length(parts)) return(NULL)

  out <- list()
  for (p in parts) {
    kv <- strsplit(p, ":", fixed = TRUE)[[1]]
    if (length(kv) != 2) {
      stop(
        "Malformed spec '", trimws(p), "'. Expected 'name:v1,v2' ",
        "(e.g. 'mean_temperature:1,3,6')."
      )
    }
    name <- trimws(kv[1])
    vals <- suppressWarnings(as.numeric(strsplit(trimws(kv[2]), ",", fixed = TRUE)[[1]]))
    if (any(is.na(vals))) {
      stop("Non-numeric value in spec for '", name, "': ", kv[2])
    }
    out[[name]] <- vals
  }
  out
}

#' Options select_re() documents per random-effect slot. Narrower than
#' write_inla_formulas() accepts (it also allows "bym"), deliberately: staying
#' with BSC's documented set keeps the modelling choices recognisably theirs.
RE_OPTIONS <- list(
  spatial = c("bym2"),
  seasonal = c("rw1", "rw2"),
  interannual = c("iid", "rw1", "rw2")
)

#' Validate random-effect choices for a slot.
#'
#' main.py constrains the single-value fields with Literal, so the API rejects
#' bad values at config creation. This is the backstop for the paths pydantic
#' does not cover: a hand-written config.yml when running the scripts directly,
#' and the comma-separated report_re_* search-space fields, which cannot be
#' expressed as Literal.
#'
#' Without this, an invalid value surfaces as GHRmodel's generic
#' "'re$re' must be one of: iid, rw1, rw2, bym, bym2" partway through a job,
#' with no indication of which parameter was at fault.
validate_re_choice <- function(values, slot) {
  if (is.null(values)) return(NULL)
  allowed <- RE_OPTIONS[[slot]]
  bad <- setdiff(values, allowed)
  if (length(bad)) {
    stop(
      "Invalid re_", slot, " value(s): ", paste(bad, collapse = ", "), "\n",
      "  allowed: ", paste(allowed, collapse = ", "), ", or 'none' to omit."
    )
  }
  values
}

#' Families the forecast path supports.
#'
#' Narrower than fit_models() accepts. fit_models() passes `family` straight to
#' INLA, but sample_ppd() dispatches on it and raises "Unsupported family" for
#' anything outside this set -- so an unsupported family fits fine and then fails
#' at the sampling step, after the expensive work is done. Checked up front.
SAMPLEABLE_FAMILIES <- c("nbinomial", "poisson")

validate_family <- function(family) {
  if (!is.character(family) || length(family) != 1 || !family %in% SAMPLEABLE_FAMILIES) {
    stop(
      "Unsupported family: ", paste(family, collapse = ", "), "\n",
      "  GHRmodel's posterior sampler supports only: ",
      paste(SAMPLEABLE_FAMILIES, collapse = ", "), "\n",
      "  Another family would fit but fail when drawing predictions."
    )
  }
  family
}

#' Split a comma-separated string into a character vector, NULL when empty or
#' when it names the sentinel "none".
parse_choices <- function(s) {
  if (is.null(s) || !nzchar(trimws(s))) return(NULL)
  v <- trimws(strsplit(trimws(s), ",", fixed = TRUE)[[1]])
  v <- v[nzchar(v) & v != "none"]
  if (!length(v)) NULL else v
}

# ---------------------------------------------------------------------------
# Data preparation
# ---------------------------------------------------------------------------

#' Derive the identifier columns GHRmodel requires by exact name.
#'
#' select_re()/write_inla_formulas() reference `spatial_id`, `seasonal_id` and
#' `year_id` literally, and require a Date-class time column. CHAP supplies
#' `time_period` as either "YYYY-MM" (monthly) or "YYYY-WNN" (weekly).
prepare_data <- function(df) {
  ptype <- detect_period_type(df$time_period)
  df$time <- parse_time_period(df$time_period)

  if (!"location" %in% names(df)) {
    stop("Input data has no 'location' column.")
  }
  df$location <- as.character(df$location)

  # Order by space then time: derive_covariates() rolls and lags on row
  # adjacency, so the rows for each location must be sorted. predict.R separately
  # calls assert_regular_periods() on each supplied series to reject missing
  # periods, which row adjacency alone cannot see.
  df <- df[order(df$location, df$time), ]

  df$spatial_id <- as.integer(as.factor(df$location))

  # seasonal_id must span one full seasonal cycle, because select_re() fits the
  # seasonal effect with cyclic = TRUE. Reading month off the date would give a
  # 12-level cycle for weekly data, silently collapsing ~4-5 weeks into one
  # level, so derive it from the period type instead.
  if (identical(ptype, "weekly")) {
    df$seasonal_id <- as.integer(sub("^.*-W", "", as.character(df$time_period)))
    df$year_id <- as.integer(sub("-W.*$", "", as.character(df$time_period)))
  } else {
    df$seasonal_id <- as.integer(format(df$time, "%m"))
    df$year_id <- as.integer(format(df$time, "%Y"))
  }

  rownames(df) <- NULL
  df
}

#' Guard against a missing period within a supplied series.
#'
#' derive_covariates() rolls and lags on ROW adjacency: a w-row window is treated
#' as w consecutive periods. If a period is missing entirely -- its row absent,
#' not NA -- the surrounding rows look adjacent and the rolling/lag values quietly
#' span the gap. predict.R's mid-series completeness check cannot see this, since
#' a missing row leaves no NA behind, and GHRmodel's own .check_consecutive() runs
#' only at fit time, after the covariates are already wrong.
#'
#' predict.R applies this to the historic and future series *separately*, so each
#' must be internally consecutive. The seam between them is deliberately not
#' constrained: CHAP supplies future contiguous with history, forecasting a later
#' window is a different concern, and asserting contiguity here would also reject
#' chapkit's own contract fixture, whose generator leaves a gap between the two
#' blocks.
#'
#' Checks the time column's spacing rather than a calendar, so it needs no period
#' arithmetic: monthly steps vary 28-31 days and the weekly parse jumps a day at
#' the year boundary, so a step is called a gap only when it exceeds 1.5x the
#' location's median step. That tolerates the natural variation but catches the
#' doubled (or larger) gap a dropped period leaves. Duplicated periods (median
#' step 0) are left to predict.R's duplicate-key check.
assert_regular_periods <- function(df) {
  gappy <- character(0)
  for (loc in unique(df$location)) {
    t <- sort(df$time[df$location == loc])
    if (length(t) < 3) next
    d <- as.numeric(diff(t))
    med <- stats::median(d)
    if (med > 0 && any(d > 1.5 * med)) gappy <- c(gappy, loc)
  }
  if (length(gappy)) {
    stop(
      "Missing period(s) in the series for location(s): ",
      paste(utils::head(gappy, 5), collapse = ", "),
      if (length(gappy) > 5) ", ..." else "", "\n",
      "  Rolling and lag terms assume consecutive periods; a gap would make ",
      "non-adjacent periods look adjacent and silently corrupt those terms. ",
      "Supply a complete series."
    )
  }
  invisible(df)
}

#' Classify CHAP's time_period format: "monthly" (YYYY-MM), "weekly" (YYYY-Wnn),
#' or "other" (parseable dates).
detect_period_type <- function(tp) {
  tp <- as.character(tp)
  if (all(grepl("^[0-9]{4}-[0-9]{2}$", tp))) return("monthly")
  if (all(grepl("^[0-9]{4}-W[0-9]{1,2}$", tp))) return("weekly")
  "other"
}

#' CHAP time_period to Date. Handles "YYYY-MM" and ISO week "YYYY-WNN".
parse_time_period <- function(tp) {
  tp <- as.character(tp)
  if (all(grepl("^[0-9]{4}-[0-9]{2}$", tp))) {
    return(as.Date(paste0(tp, "-01")))
  }
  if (all(grepl("^[0-9]{4}-W[0-9]{1,2}$", tp))) {
    yr <- as.integer(sub("-W.*$", "", tp))
    wk <- as.integer(sub("^.*-W", "", tp))
    return(as.Date(paste0(yr, "-01-01")) + (wk - 1) * 7)
  }
  d <- suppressWarnings(as.Date(tp))
  if (any(is.na(d))) {
    stop("Unrecognised time_period format: ", paste(utils::head(unique(tp), 3), collapse = ", "))
  }
  d
}

#' Build the adjacency matrix GHRmodel's bym2 effect needs.
#'
#' Returned as a matrix that the caller must bind to the name `g` in the
#' environment fit_models() is called from -- the generated INLA formula
#' references `graph = g` by name, it is not passed as an argument.
#'
#' Returns NULL only when no geometry was supplied at all -- a legitimate
#' deployment, where the caller drops the spatial term.
#'
#' If geometry IS supplied but cannot be matched to the data, this raises rather
#' than returning NULL. Silently dropping bym2 there would fit a materially
#' different model while reporting success, which is how BSC's own Laos demo
#' would misbehave: their GADM polygon names ("Louangnamtha", "Xiangkhouang",
#' "Vientiane") do not match the data's ("LouangNamtha", "Xiangkhoang",
#' "Vientiane[prefecture]") and they patch them by hand before use.
build_graph <- function(geo_path, locations) {
  if (is.null(geo_path)) {
    message("No geometry supplied; spatial random effect disabled.")
    return(NULL)
  }
  ok <- requireNamespace("sf", quietly = TRUE) && requireNamespace("spdep", quietly = TRUE)
  if (!ok) {
    stop("Geometry was supplied but sf/spdep are unavailable.")
  }

  polys <- try(sf::st_read(geo_path, quiet = TRUE), silent = TRUE)
  if (inherits(polys, "try-error")) {
    stop("Geometry was supplied but could not be read: ", geo_path)
  }

  # Find whichever column carries the location identifier, then order the
  # polygons to match as.factor(location) -- that is the ordering spatial_id
  # was built from, and the graph rows must line up with it.
  wanted <- sort(unique(locations))
  id_col <- NULL
  for (nm in names(polys)) {
    vals <- as.character(polys[[nm]])
    if (all(wanted %in% vals)) {
      id_col <- nm
      break
    }
  }
  if (is.null(id_col)) {
    # Report the closest candidate property so the mismatch is diagnosable
    # rather than just "no match".
    best <- NULL
    best_hit <- -1
    for (nm in names(polys)) {
      hit <- sum(wanted %in% as.character(polys[[nm]]))
      if (hit > best_hit) {
        best_hit <- hit
        best <- nm
      }
    }
    stop(
      "Geometry was supplied but no property matches the data's locations.\n",
      "  data locations (", length(wanted), "): ",
      paste(utils::head(wanted, 5), collapse = ", "),
      if (length(wanted) > 5) ", ..." else "", "\n",
      "  closest property '", best, "' matched ", best_hit, "/", length(wanted), ": ",
      paste(utils::head(unique(as.character(polys[[best]])), 5), collapse = ", "), "\n",
      "  Fix the identifiers so they agree, or omit geometry to run without a ",
      "spatial effect."
    )
  }

  # match() takes the first hit, so duplicate features for one location would be
  # silently discarded and the adjacency built from an arbitrary one.
  ids <- as.character(polys[[id_col]])
  dup_ids <- unique(ids[ids %in% wanted & duplicated(ids)])
  if (length(dup_ids)) {
    stop(
      "Geometry has more than one feature for location(s): ",
      paste(utils::head(dup_ids, 5), collapse = ", "),
      if (length(dup_ids) > 5) ", ..." else "", "\n",
      "  Dissolve them to one feature per location before use."
    )
  }

  polys <- polys[match(wanted, ids), ]
  nb <- spdep::poly2nb(polys)

  # A disconnected graph is legal but weakens bym2 -- areas in separate
  # components share no spatial smoothing. Say so rather than let it pass
  # unremarked; BSC's own Laos example has 5 components across 7 areas.
  n_isolated <- sum(vapply(nb, function(x) identical(x, 0L), logical(1)))
  if (n_isolated > 0) {
    message(
      n_isolated, " of ", length(nb), " areas have no neighbours. The bym2 ",
      "effect will do little spatial smoothing for them."
    )
  }
  if (all(vapply(nb, function(x) identical(x, 0L), logical(1)))) {
    stop("Geometry was supplied but yields no shared borders between areas.")
  }
  spdep::nb2mat(nb, style = "B", zero.policy = TRUE)
}

# ---------------------------------------------------------------------------
# Covariate derivation
# ---------------------------------------------------------------------------

#' Derive rolling and lagged covariate columns.
#'
#' Deliberately reproduces select_fe()'s naming so that anything a user reads in
#' a BSC selection report lines up with what this wrapper fits:
#'   window 1  -> "<cov>.noroll"      window w -> "<cov>.rmean<w>" / ".rsum<w>"
#'   lag 0     -> "<var>.l0"          lag t    -> "<var>.l<t>"
derive_covariates <- function(data, covariates, roll_mean, roll_sum, lag, standardize, time_col, area_col) {
  derived <- character(0)

  # Rolling transforms, per covariate. A covariate with no entry passes through
  # untransformed.
  for (cov in covariates) {
    if (!cov %in% names(data)) {
      stop("Covariate '", cov, "' not found in the data.")
    }
    made <- character(0)

    for (spec in list(list(v = roll_mean, fn = mean, tag = "rmean"),
                      list(v = roll_sum, fn = sum, tag = "rsum"))) {
      if (is.null(spec$v) || !cov %in% names(spec$v)) next
      for (w in spec$v[[cov]]) {
        if (w == 1) {
          newvar <- paste0(cov, ".noroll")
          data[[newvar]] <- data[[cov]]
        } else {
          newvar <- paste0(cov, ".", spec$tag, w)
          data[[newvar]] <- ave_by(
            data[[cov]], data[[area_col]],
            function(x) zoo::rollapply(x, w, spec$fn, align = "right", partial = TRUE)
          )
        }
        made <- c(made, newvar)
      }
    }

    # No roll spec for this covariate: select_fe() still emits "<cov>.noroll"
    # (the else branches of its roll_mean/roll_sum loops), so match that rather
    # than keeping the raw name, or derived terms won't line up with the names
    # a user reads in a selection report.
    #
    # Deliberately NOT mirroring select_fe() further here. There, the roll_sum
    # else branch also fires for covariates that *do* have a roll_mean entry,
    # so tmax with roll_mean=3 yields both tmax.noroll and tmax.rmean3. That is
    # correct for select_fe, where each derived column is a separate univariable
    # candidate competing for n_select_uni slots. This wrapper puts every term
    # into one formula, so replicating it would place a variable and its own
    # rolling mean in the same regression as collinear predictors.
    if (!length(made)) {
      newvar <- paste0(cov, ".noroll")
      data[[newvar]] <- data[[cov]]
      made <- newvar
    }
    derived <- c(derived, made)
  }
  derived <- unique(derived)

  # Lags, applied to the rolled columns. Lagging is grouped by area so a series
  # never borrows values from its neighbour.
  lagged <- character(0)
  for (var in derived) {
    base_cov <- sub("\\.(noroll|rmean[0-9]+|rsum[0-9]+)$", "", var)
    lags <- if (!is.null(lag) && base_cov %in% names(lag)) lag[[base_cov]] else 0
    for (t in lags) {
      if (t == 0) {
        newvar <- paste0(var, ".l0")
        data[[newvar]] <- data[[var]]
      } else {
        newvar <- paste0(var, ".l", t)
        data[[newvar]] <- ave_by(data[[var]], data[[area_col]], function(x) shift_n(x, t))
      }
      lagged <- c(lagged, newvar)
    }
  }
  lagged <- unique(lagged)

  if (isTRUE(standardize)) {
    degenerate <- character(0)
    for (v in lagged) {
      mu <- mean(data[[v]], na.rm = TRUE)
      sdv <- stats::sd(data[[v]], na.rm = TRUE)
      if (is.finite(sdv) && sdv > 0) {
        data[[v]] <- (data[[v]] - mu) / sdv
      } else {
        degenerate <- c(degenerate, v)
      }
    }
    # A zero-variance predictor carries no information and cannot be
    # standardized. Skipping it quietly leaves a constant column in the design
    # matrix, which INLA will fit with a meaningless coefficient. Say so.
    if (length(degenerate)) {
      stop(
        "Covariate term(s) have zero or undefined variance: ",
        paste(degenerate, collapse = ", "), "\n",
        "  A constant predictor cannot be standardized or estimated. Check the ",
        "input data, or drop the covariate."
      )
    }
  }

  list(data = data, covariates = lagged)
}

#' Apply a vector-preserving function within each group.
ave_by <- function(x, grp, fn) {
  out <- x
  for (g in unique(grp)) {
    idx <- which(grp == g)
    out[idx] <- fn(x[idx])
  }
  out
}

#' Shift a vector forward by n, padding the head with NA.
shift_n <- function(x, n) {
  if (n <= 0) return(x)
  c(rep(NA_real_, n), utils::head(x, -n))
}

#' Derived terms belonging to covariate `cov`, matched on the "<cov>." name
#' boundary. Every derived name is "<cov>.<roll>.l<t>", so a bare prefix would
#' also match a longer covariate ("temp" catching "temperature", "rain" catching
#' "rainfall"). Used to scope non-linear replacement to exactly the covariate the
#' user named.
cov_terms_for <- function(terms, cov) {
  terms[startsWith(terms, paste0(cov, "."))]
}

#' The forecast fits a single formula, so each covariate takes one non-linear
#' knot count. Reject a spec that gives more than one: that is a selection-search
#' idea with no meaning for one formula, and applying cov_nl() once per value
#' would feed its own output (formula strings) back into the second pass.
validate_nl_spec <- function(nl_spec) {
  if (is.null(nl_spec)) return(invisible(NULL))
  multi <- names(nl_spec)[vapply(nl_spec, length, integer(1)) > 1]
  if (length(multi)) {
    stop(
      "nl gives more than one knot count for: ", paste(multi, collapse = ", "),
      ".\n  The forecast fits a single formula, so each covariate takes one ",
      "non-linear knot count. Use one value per covariate, e.g. '",
      multi[1], ":", nl_spec[[multi[1]]][1], "'."
    )
  }
  invisible(nl_spec)
}

# ---------------------------------------------------------------------------
# Formula construction
# ---------------------------------------------------------------------------

#' Build the random effect argument lists for write_inla_formulas().
#'
#' Returns a list of up to three re specs, in BSC's order (spatial, seasonal,
#' interannual), with anything set to "none" omitted. `hyper` and `graph` are
#' passed as the *names* "prec1" and "g" because GHRmodel emits them literally
#' into the formula string, to be resolved from the calling environment at fit
#' time.
build_re_specs <- function(cfg, has_graph) {
  specs <- list()

  spatial <- validate_re_choice(parse_choices(cfg$re_spatial), "spatial")
  if (!isTRUE(has_graph)) spatial <- NULL
  if (!is.null(spatial)) {
    specs[[length(specs) + 1]] <- list(
      id = "spatial_id", model = spatial[1], graph = "g",
      scale.model = TRUE, constr = TRUE, hyper = "prec1"
    )
  }

  seasonal <- validate_re_choice(parse_choices(cfg$re_seasonal), "seasonal")
  if (!is.null(seasonal)) {
    specs[[length(specs) + 1]] <- list(
      id = "seasonal_id", model = seasonal[1], cyclic = TRUE,
      scale.model = TRUE, constr = TRUE, hyper = "prec1"
    )
  }

  interannual <- validate_re_choice(parse_choices(cfg$re_interannual), "interannual")
  if (!is.null(interannual)) {
    specs[[length(specs) + 1]] <- list(
      id = "year_id", model = interannual[1],
      constr = TRUE, hyper = "prec1"
    )
  }

  specs
}

#' Resolve and validate the offset column, and apply offset_scale.
#'
#' Shared by train.R and predict.R deliberately. These must agree exactly: if
#' the report ranks models fitted on one offset scale and the forecast uses
#' another, the selected configuration no longer corresponds to what gets fitted.
#' They drifted apart once already.
#'
#' Returns a list(data, offset_col), with offset_col NULL when no offset is used.
apply_offset <- function(data, cfg) {
  offset_col <- if (nzchar(cfg$offset)) cfg$offset else NULL
  if (is.null(offset_col)) {
    return(list(data = data, offset_col = NULL))
  }
  if (!offset_col %in% names(data)) {
    stop("Offset column '", offset_col, "' not found in the data.")
  }

  # log(offset) is undefined at or below zero, so INLA would fail with a far
  # less obvious error.
  bad <- !is.finite(data[[offset_col]]) | data[[offset_col]] <= 0
  if (any(bad)) {
    stop(sum(bad), " row(s) have a non-positive or missing '", offset_col, "'.")
  }

  scale <- suppressWarnings(as.numeric(cfg$offset_scale))
  if (length(scale) != 1 || !is.finite(scale) || scale <= 0) {
    # Previously an unusable value was skipped silently, leaving the offset
    # unscaled and the run looking fine.
    stop(
      "offset_scale must be a single positive number, got: ",
      paste(utils::capture.output(print(cfg$offset_scale)), collapse = " "), "\n",
      "  Use 1 to disable scaling."
    )
  }
  if (scale != 1) {
    data[[offset_col]] <- data[[offset_col]] / scale
    cat("Scaled offset '", offset_col, "' by 1/", format(scale, scientific = FALSE),
        "\n", sep = "")
  }
  list(data = data, offset_col = offset_col)
}

#' PC prior on a random effect precision, in INLA's expected shape.
make_prior <- function(u, alpha) {
  list(prec = list(prior = "pc.prec", param = c(u, alpha)))
}

#' Parse the "U:alpha;U:alpha" prior encoding and bind each pair as prec1,
#' prec2, ... in `env`.
#'
#' GHRmodel resolves priors by *name* -- select_re() takes prior = c("prec1",
#' "prec2") and writes `hyper = prec1` into the formula string, leaving INLA to
#' look the object up at fit time. So the objects must exist in the environment
#' the fit runs from, under exactly those names.
#'
#' Binds into the global environment by default, and that is load-bearing rather
#' than lazy. GHRmodel checks for these with a bare `exists()` from inside its
#' own namespace, and INLA resolves `hyper = prec1` / `graph = g` out of the
#' formula's environment at fit time. Both searches walk the package namespace's
#' parent chain, which reaches globalenv() but never the frame of a wrapper
#' function. Binding into a local frame yields
#' "Spatial graph 'g' not found in the environment".
#'
#' Returns the character vector of names created, in order.
bind_priors <- function(spec, env = globalenv()) {
  pairs <- parse_spec_pairs(spec)
  if (!length(pairs)) {
    stop("No valid priors parsed from '", spec, "'. Expected 'U:alpha' pairs.")
  }
  names_out <- character(0)
  for (i in seq_along(pairs)) {
    nm <- paste0("prec", i)
    assign(nm, make_prior(pairs[[i]][1], pairs[[i]][2]), envir = env)
    names_out <- c(names_out, nm)
  }
  names_out
}

#' Parse "0.5:0.01;1:0.01" into a list of c(U, alpha) numeric pairs.
parse_spec_pairs <- function(s) {
  if (is.null(s) || !nzchar(trimws(s))) return(list())
  parts <- strsplit(trimws(s), ";", fixed = TRUE)[[1]]
  parts <- parts[nzchar(trimws(parts))]
  out <- list()
  for (p in parts) {
    kv <- suppressWarnings(as.numeric(strsplit(trimws(p), ":", fixed = TRUE)[[1]]))
    if (length(kv) != 2 || any(is.na(kv))) {
      stop("Malformed prior '", trimws(p), "'. Expected 'U:alpha', e.g. '0.5:0.01'.")
    }
    out[[length(out) + 1]] <- kv
  }
  out
}
