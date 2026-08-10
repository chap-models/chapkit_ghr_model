# BSC's random-effect selection report.
#
# Kept out of train.R so the standard train entry point stays what it says it is:
# validate inputs, write a placeholder. This file is sourced only when
# emit_re_selection_report is on, so nothing here can affect a normal training
# run.
#
# Covers select_re() only. BSC's full workflow is select_re() then select_fe();
# the fixed-effect search is out of scope for this version -- see README.

#' Run select_re() over the configured search space and render BSC's HTML report.
#'
#' Writes two files into the working directory, which chapkit zips into the
#' ml_training_workspace artifact:
#'   selection_report_re.html   BSC's rendered comparison
#'   selection_re.rds           the GHRselect_re object behind it
#'
#' Returns TRUE on success, FALSE on failure. Never raises: the forecast does not
#' depend on the report, so a failed report must not fail training.
run_re_selection_report <- function(df, cfg, geo_file, offset_col) {
  cat("\nemit_re_selection_report is on. Running select_re() search.\n")
  cat("This fits many candidate models and is far slower than the forecast.\n")

  graph <- build_graph(geo_file, df$location)

  # `g` and the priors must land in the GLOBAL environment, not this function's
  # frame. select_re() checks with a bare exists("g") from inside the GHRmodel
  # namespace, and INLA resolves `graph = g` / `hyper = prec1` out of the
  # formula environment at fit time; both searches walk the namespace's parent
  # chain to globalenv() and never see a wrapper function's locals. A local
  # binding fails with "Spatial graph 'g' not found in the environment".
  #
  # This is why the report code works when run at top level and needs explicit
  # global assignment once it lives in a function.
  assign("g", graph, envir = globalenv())
  on.exit(suppressWarnings(rm("g", envir = globalenv())), add = TRUE)

  prior_names <- bind_priors(cfg$priors, env = globalenv())
  on.exit(
    suppressWarnings(rm(list = prior_names, envir = globalenv())),
    add = TRUE
  )
  cat("Searching over priors:", paste(prior_names, collapse = ", "), "\n")

  # The search space comes entirely from the report_re_* fields, for all three
  # slots, independent of the re_* fields that pin the forecast's single
  # configuration. These are comma-separated sets, so they cannot be constrained
  # by Literal in main.py -- validate them here.
  report_spatial <- validate_re_choice(parse_choices(cfg$report_re_spatial), "spatial")
  report_seasonal <- validate_re_choice(parse_choices(cfg$report_re_seasonal), "seasonal")
  report_interannual <- validate_re_choice(
    parse_choices(cfg$report_re_interannual), "interannual"
  )

  # No geometry means no adjacency graph, so a spatial term cannot be fitted
  # regardless of what was configured.
  if (is.null(graph)) report_spatial <- NULL

  ok <- try(
    {
      sel <- GHRmodel::select_re(
        data = df,
        outcome = "disease_cases",
        prior = prior_names,
        time = "time",
        area = "location",
        offset = offset_col,
        re_spatial = report_spatial,
        re_seasonal = report_seasonal,
        re_interannual = report_interannual,
        family = cfg$family,
        nthreads = cfg$nthreads
      )
      # select_report() hard-requires a .html extension. chapkit has no report
      # entry point and imposes no PDF requirement, so HTML ships as-is and
      # BSC's code needs no modification.
      GHRmodel::select_report(sel, "selection_report_re.html")
      saveRDS(sel, "selection_re.rds")
      TRUE
    },
    silent = FALSE
  )

  if (inherits(ok, "try-error")) {
    cat("WARNING: selection report failed; continuing without it.\n")
    return(FALSE)
  }
  cat("Selection report written to selection_report_re.html\n")
  TRUE
}
