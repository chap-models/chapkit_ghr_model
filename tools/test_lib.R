# Unit checks for the pure helpers in scripts/lib.R.
#
# Development tooling, not shipped in the image. Run with:
#   docker run --rm -v "$PWD":/work <image> Rscript tools/test_lib.R
#
# These are the functions where a silent wrong answer is plausible: period
# handling, the nested-parameter encodings, and the CLI arg guard.

source("scripts/lib.R")

fails <- 0
check <- function(label, actual, expected) {
  ok <- isTRUE(all.equal(actual, expected))
  cat(sprintf("%-58s %s\n", label, if (ok) "ok" else "FAIL"))
  if (!ok) {
    cat("   expected: ", paste(utils::capture.output(print(expected)), collapse = " "), "\n")
    cat("   actual:   ", paste(utils::capture.output(print(actual)), collapse = " "), "\n")
    fails <<- fails + 1
  }
}

cat("== period type detection ==\n")
check("monthly", detect_period_type(c("2019-01", "2019-02")), "monthly")
check("weekly", detect_period_type(c("2019-W01", "2019-W02")), "weekly")
check("weekly single digit", detect_period_type(c("2019-W1", "2019-W2")), "weekly")
check("other (full dates)", detect_period_type(c("2019-01-01")), "other")

cat("\n== seasonal_id / year_id derivation ==\n")
# Monthly: seasonal_id is the month, cycle length 12.
m <- prepare_data(data.frame(
  time_period = c("2019-01", "2019-06", "2019-12"),
  location = "A", stringsAsFactors = FALSE
))
check("monthly seasonal_id", m$seasonal_id, c(1L, 6L, 12L))
check("monthly year_id", m$year_id, c(2019L, 2019L, 2019L))

# Weekly: seasonal_id must be week-of-year, not month. Reading month off the
# date would give c(1,6,12)-ish and collapse the 52-week cycle to 12 levels.
w <- prepare_data(data.frame(
  time_period = c("2019-W01", "2019-W26", "2019-W52"),
  location = "A", stringsAsFactors = FALSE
))
check("weekly seasonal_id is week-of-year", w$seasonal_id, c(1L, 26L, 52L))
check("weekly year_id", w$year_id, c(2019L, 2019L, 2019L))

cat("\n== spec parsing ==\n")
check("empty -> NULL", parse_spec(""), NULL)
check("single", parse_spec("a:3"), list(a = 3))
check("multi value", parse_spec("a:1,3,6"), list(a = c(1, 3, 6)))
check("multi covariate", parse_spec("a:1;b:2,4"), list(a = 1, b = c(2, 4)))
check("whitespace tolerant", parse_spec(" a : 1 , 3 ; b : 2 "), list(a = c(1, 3), b = 2))

cat("\n== prior parsing ==\n")
check("single pair", parse_spec_pairs("0.5:0.01"), list(c(0.5, 0.01)))
check("two pairs", parse_spec_pairs("0.5:0.01;1:0.01"), list(c(0.5, 0.01), c(1, 0.01)))

e <- new.env()
nm <- bind_priors("0.5:0.01;1:0.01", env = e)
check("binds prec1/prec2 by name", nm, c("prec1", "prec2"))
check("prec2 params", get("prec2", envir = e)$prec$param, c(1, 0.01))

cat("\n== choices ==\n")
check("none -> NULL", parse_choices("none"), NULL)
check("empty -> NULL", parse_choices(""), NULL)
check("list", parse_choices("rw1,rw2"), c("rw1", "rw2"))

cat("\n== RE option validation ==\n")
check("valid seasonal passes", validate_re_choice(c("rw1", "rw2"), "seasonal"), c("rw1", "rw2"))
check("valid interannual passes", validate_re_choice("iid", "interannual"), "iid")
check("NULL passes through", validate_re_choice(NULL, "spatial"), NULL)

bad_msg <- tryCatch({
  validate_re_choice("garbage", "seasonal"); "no error"
}, error = function(e) conditionMessage(e))
check("invalid value rejected", grepl("Invalid re_seasonal", bad_msg), TRUE)
check("error names the parameter", grepl("garbage", bad_msg), TRUE)
check("error lists allowed values", grepl("rw1, rw2", bad_msg), TRUE)

# iid is valid for interannual but not seasonal -- slots differ.
slot_msg <- tryCatch({
  validate_re_choice("iid", "seasonal"); "no error"
}, error = function(e) conditionMessage(e))
check("slot-specific: iid invalid for seasonal", grepl("Invalid re_seasonal", slot_msg), TRUE)

cat("\n== offset handling ==\n")
d0 <- data.frame(population = c(10000, 20000), x = 1:2)
r <- apply_offset(d0, list(offset = "population", offset_scale = 10000))
check("scales by offset_scale", r$data$population, c(1, 2))
check("returns offset_col", r$offset_col, "population")

r1 <- apply_offset(d0, list(offset = "", offset_scale = 1))
check("empty offset disables", r1$offset_col, NULL)

bad_scale <- tryCatch({
  apply_offset(d0, list(offset = "population", offset_scale = 0)); "no error"
}, error = function(e) conditionMessage(e))
check("offset_scale 0 rejected", grepl("must be a single positive number", bad_scale), TRUE)

neg <- tryCatch({
  apply_offset(data.frame(population = c(0, 5)), list(offset = "population", offset_scale = 1))
  "no error"
}, error = function(e) conditionMessage(e))
check("non-positive offset rejected", grepl("non-positive or missing", neg), TRUE)

cat("\n== zero-variance covariate ==\n")
const_df <- data.frame(
  loc = rep("A", 6), t = 1:6,
  flat = rep(5, 6), varying = c(1, 2, 3, 4, 5, 6),
  stringsAsFactors = FALSE
)
zv <- tryCatch({
  derive_covariates(const_df, "flat", NULL, NULL, NULL, TRUE, "t", "loc"); "no error"
}, error = function(e) conditionMessage(e))
check("constant covariate rejected", grepl("zero or undefined variance", zv), TRUE)

ok_dc <- derive_covariates(const_df, "varying", NULL, NULL, NULL, TRUE, "t", "loc")
check("varying covariate accepted", ok_dc$covariates, "varying.noroll.l0")

cat("\n== nl term selection is boundary-aware ==\n")
# Derived names are "<cov>.<roll>.l<t>". A bare prefix over-matches a longer
# covariate; cov_terms_for() matches on the "<cov>." boundary instead.
sel <- c("temp.noroll.l0", "temperature.rmean3.l1", "max_temp.noroll.l0")
check("bare prefix over-matches the nested name (the bug)",
      sel[startsWith(sel, "temp")], c("temp.noroll.l0", "temperature.rmean3.l1"))
check("cov_terms_for excludes nested and sibling names",
      cov_terms_for(sel, "temp"), "temp.noroll.l0")
check("cov_terms_for selects the longer name when named",
      cov_terms_for(sel, "temperature"), "temperature.rmean3.l1")

cat("\n== nl single knot count per covariate ==\n")
check("single value passes", validate_nl_spec(list(a = 8)), list(a = 8))
check("NULL passes", validate_nl_spec(NULL), NULL)
nl_multi <- tryCatch({
  validate_nl_spec(list(a = c(3, 8))); "no error"
}, error = function(e) conditionMessage(e))
check("multiple knot counts rejected", grepl("more than one knot count", nl_multi), TRUE)
check("error names the covariate", grepl("for: a", nl_multi), TRUE)

cat("\n== regular-period assertion ==\n")
# A missing row (period absent, not NA) makes non-adjacent periods look adjacent;
# rolling/lag would silently span it, so predict.R rejects it per supplied series.
reg <- prepare_data(data.frame(
  time_period = sprintf("2019-%02d", 1:6), location = "A", stringsAsFactors = FALSE
))
ok_series <- tryCatch({ assert_regular_periods(reg); "ok" }, error = function(e) conditionMessage(e))
check("complete monthly series passes", ok_series, "ok")
gap <- prepare_data(data.frame(
  time_period = c("2019-01", "2019-02", "2019-03", "2019-07", "2019-08"),
  location = "A", stringsAsFactors = FALSE
))
gap_msg <- tryCatch({ assert_regular_periods(gap); "no error" }, error = function(e) conditionMessage(e))
check("missing months rejected", grepl("Missing period", gap_msg), TRUE)

cat("\n== family validation ==\n")
check("nbinomial accepted", validate_family("nbinomial"), "nbinomial")
check("poisson accepted", validate_family("poisson"), "poisson")
fam <- tryCatch({
  validate_family("zeroinflatednbinomial1"); "no error"
}, error = function(e) conditionMessage(e))
# fit_models() would accept this; sample_ppd() would not, after the expensive fit.
check("unsampleable family rejected", grepl("Unsupported family", fam), TRUE)
check("error names the supported set", grepl("nbinomial, poisson", fam), TRUE)

cat("\n== CLI arg guard ==\n")
# chapkit substitutes {geo_file} with "" when no geometry is supplied, so
# --geo collapses to a bare flag and must not swallow the next one.
a <- parse_args(c("--historic", "h.csv", "--geo", "--output", "o.csv"),
                c("historic", "geo", "output"))
check("bare --geo does not eat --output", a$geo, NULL)
check("output still parsed", a$output, "o.csv")
check("historic parsed", a$historic, "h.csv")

cat("\n")
if (fails > 0) {
  cat("FAILED:", fails, "check(s)\n")
  quit(status = 1)
}
cat("ALL CHECKS PASSED\n")
