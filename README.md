# GHRmodel (chapkit)

> Bayesian hierarchical spatio-temporal disease-forecasting model (BSC's GHRmodel, built on R-INLA), wrapped as a [chapkit](https://github.com/dhis2-chap/chapkit) service and ready to plug into [chap-core](https://github.com/dhis2-chap/chap-core).

[![CI](https://github.com/chap-models/chapkit_ghr_model/actions/workflows/ci.yml/badge.svg)](https://github.com/chap-models/chapkit_ghr_model/actions/workflows/ci.yml)
[![Docker](https://github.com/chap-models/chapkit_ghr_model/actions/workflows/publish-docker.yml/badge.svg)](https://github.com/chap-models/chapkit_ghr_model/actions/workflows/publish-docker.yml)
[![GHCR](https://img.shields.io/badge/ghcr.io-chap--models%2Fchapkit__ghr__model-blue?logo=docker)](https://github.com/chap-models/chapkit_ghr_model/pkgs/container/chapkit_ghr_model)
[![Python](https://img.shields.io/badge/python-3.13%2B-blue)](https://www.python.org/)
[![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

A chapkit ML service wrapping [GHRmodel](https://gitlab.earth.bsc.es/ghr/ghrmodel)
(`dhis2-workflow` branch) from the Global Health Resilience group at the
Barcelona Supercomputing Center.

GHRmodel fits Bayesian hierarchical spatio-temporal models for climate-sensitive
disease using R-INLA. This service runs **one** user-specified model
configuration, with every parameter BSC's workflow lets you select exposed as a
config field.

No GHRmodel source is modified — the wrapper drives only its exported API, per
BSC's request that we wrap rather than edit their modelling code.

## Scope

BSC's workflow is a three-stage, human-in-the-loop model *selection* process:
`select_re()` ranks random-effect structures, `select_fe()` ranks covariate
configurations, `select_report()` renders the comparison for a human to read.
Neither `select_*` function returns a fitted model.

This service implements the narrower first step: run a single configuration end
to end. The multi-configuration search is available as an
optional report (see `emit_re_selection_report` below) but does not drive the
forecast. Supporting full interactive selection is a later iteration.

## How it works

Training is a **no-op**. The forecast needs a model fitted over historic+future
rows with future outcomes blanked, which only the predict step can do, so all
fitting happens there. This mirrors the existing chapkit EWARS model.

Prediction drives GHRmodel's exported API:

```
write_inla_formulas()   one formula from the configured REs + derived covariates
as_GHRformulas()        returns a character vector; fit_models() needs the class
fit_models()            keep_inla_object=TRUE and config=TRUE are both required
sample_ppd()            posterior draws for the future rows only, via pred_idx
```

Two values are bound as plain names in the **global** environment on purpose:
GHRmodel writes `graph = g` and `hyper = prec1` literally into the formula
string, and they are not passed as arguments.

Global specifically, not merely "the caller's" environment. `select_re()` checks
with a bare `exists("g")` from inside the GHRmodel namespace, and INLA resolves
those names out of the formula environment at fit time; both searches walk the
package namespace's parent chain, which reaches `globalenv()` but never a wrapper
function's frame. Binding them as locals fails with
`Spatial graph 'g' not found in the environment`.

This matters when refactoring. `predict.R` assigns them at top level, which is
global by definition — moving that code into a function without an explicit
`assign(..., envir = globalenv())` will break it. `scripts/selection_report.R`
does exactly that, with `on.exit()` cleanup so the globals do not leak.

## Layout

```
main.py            chapkit service definition and config schema
scripts/           what the runner invokes, and nothing else
  lib.R              shared wrapper helpers
  train.R            train entry point: validate + placeholder (no-op)
  selection_report.R optional RE selection report, sourced only when enabled
  predict.R          predict entry point (fit + posterior draws)
tools/             development tooling, not shipped in the image
  make_example_data.R  regenerates example_data/ from dengue_MS
  api_smoke.py         end-to-end API test, driven by `make test-api`
  test_lib.R           unit checks, driven by `make test-unit`
example_data/      fixtures
```

## Usage

```bash
make build          # build the image
make run            # run the service on :8000
make test-unit      # unit checks for the helpers in scripts/lib.R
make test-local     # run train.R + predict.R directly against example_data
make test-contract  # chapkit's own contract test (synthetic data, no geo)
make test-api       # train + predict as real API jobs, with real geometry
```

Or run the prebuilt image from GHCR (once published):

```bash
docker compose -f compose.ghcr.yml up   # service on :8000
```

## Configuration

| Field | Default | Notes |
|---|---|---|
| `prediction_periods` | 3 | Forecast horizon |
| `re_spatial` | `bym2` | `bym2` or `none`; needs geometry |
| `re_seasonal` | `rw1` | `rw1`, `rw2`, `none` |
| `re_interannual` | `iid` | `iid`, `rw1`, `rw2`, `none` |
| `priors` | `0.5:0.01` | PC priors as `U:alpha` pairs; `P(sigma > U) = alpha` |
| `additional_continuous_covariates` | `[rainfall, mean_temperature]` | Fixed effects |
| `roll_mean` / `roll_sum` | `mean_temperature:3` / `rainfall:3` | Rolling windows |
| `lag` | `mean_temperature:1;rainfall:1` | Lags in periods |
| `nl` | `""` | Non-linear effects, `name:knots` |
| `standardize` | `true` | Centre and scale covariates |
| `family` | `nbinomial` | INLA likelihood |
| `offset` / `offset_scale` | `population` / 10000 | See below |
| `n_samples` | 1000 | Posterior draws per row |
| `emit_re_selection_report` | `false` | Random-effect search report. See below |
| `report_re_spatial` | `bym2` | Report search space, comma-separated |
| `report_re_seasonal` | `rw1,rw2` | Report search space, comma-separated |
| `report_re_interannual` | `iid,rw1,rw2` | Report search space, comma-separated |

The `re_*` fields set the single configuration the **forecast** fits. The
`report_re_*` fields set the search space the **report** explores. They are
independent: turning the spatial term off in the forecast does not narrow the
report's search.

### Random effect models

`bym2`, `rw1`, `rw2` and `iid` are **R-INLA latent model names**, not GHRmodel's
own vocabulary. They describe how the levels of a random effect relate to one
another:

| name | what it does |
|---|---|
| `iid` | Independent per level — each year (or area) gets its own offset, unrelated to its neighbours. Handles shocks well; cannot extrapolate a trend to an unseen level. |
| `rw1` | Random walk, order 1. Ties each level to the previous one, smoothing the *level*. |
| `rw2` | Random walk, order 2. Penalises change in the *slope* instead, giving a smoother, more curved shape. |
| `bym2` | Besag-York-Mollie, in the parameterisation of Simpson et al. (2017). Combines a spatially structured component — neighbouring areas share information through the adjacency graph — with an unstructured per-area component, rescaled so one hyperparameter is total variance and the other is the proportion of it that is spatially structured. That is what makes PC priors interpretable on it, and why BSC use it. |

Three modifiers appear in the generated formulas and are set by the wrapper, not
configurable:

- `cyclic = TRUE` on the seasonal effect — wraps the walk so December connects
  back to January.
- `scale.model = TRUE` — rescales the effect so a prior means the same thing
  regardless of the graph or series length.
- `constr = TRUE` — sum-to-zero constraint, so the random effect does not compete
  with the intercept.

The `priors` field sets a penalised-complexity prior on these effects' precision:
`U:alpha` reads as `P(sigma > U) = alpha`. Per Simpson et al., PC priors shrink
toward the simpler model unless the data argue otherwise, and are set on an
interpretable scale (the effect's standard deviation).

**Where to read more.** GHRmodel documents these well in its vignettes — see
`vignettes/GHRmodel_overview.Rmd` in the GHRmodel repo
(`https://gitlab.earth.bsc.es/ghr/ghrmodel`, branch `dhis2-workflow`), which
covers BYM vs BYM2 and the adjacency matrix (~line 334) and the full
random-effect specification (~497-531). Those vignettes are **not installed in
the service image** — installing from a source directory skips vignette building
— so clone the repo to read them. The `man/` pages only enumerate valid values.

INLA itself: `inla.doc("bym2")`, `inla.list.models("latent")`. Primary sources:
Besag, York and Mollié (1991) for BYM; Simpson et al. (2017) for BYM2 and PC
priors — both cited in GHRmodel's vignettes.

One difference from BSC's manual examples worth knowing: their overview vignette
also sets a `phi` prior on BYM2's mixing parameter. `select_re()` takes only a
precision prior, and their own `pipeline.R` passes only that, so this wrapper
matches `select_re()` rather than the vignette.

### The nested-parameter encoding

`roll_mean`, `roll_sum`, `lag` and `nl` are named lists of numeric vectors in R
(`list(mean_temperature = c(1, 3, 6))`), which flat config fields cannot express.
The encoding is:

```
"mean_temperature:1,3,6;rainfall:1,3"
```

Semicolons separate covariates, commas separate values. An empty string disables
the transform. Multiple values put several terms in the same model — `lag =
"rainfall:1,3"` gives both `rainfall.l1` and `rainfall.l3` as fixed effects.

`priors` uses the same shape with `U:alpha` pairs — `"0.5:0.01;1:0.01"` binds
`prec1` and `prec2`, matching BSC's demo. The forecast fits with the first;
`emit_re_selection_report` searches over all of them. They are bound as plain
names in the global environment because `select_re()` takes
`prior = c("prec1", "prec2")` and resolves the objects by name at fit time — see
the note above on why global specifically.

### Geometry is strict

Supplying no geometry is fine — the spatial effect is dropped and the run
continues. But supplying geometry that does not match the data is an **error**,
not a silent fallback, because quietly dropping `bym2` fits a materially
different model while reporting success.

This is not hypothetical: BSC's own Laos demo hits it. Their GADM polygons are
named `Louangnamtha`, `Xiangkhouang`, `Vientiane` while the data says
`LouangNamtha`, `Xiangkhoang`, `Vientiane[prefecture]`, and `pipeline.R` patches
them by hand. The error names the closest-matching property and its hit rate so
the mismatch is diagnosable.

### Derived covariate naming

Derived columns follow `select_fe()`'s naming so terms line up with what a user
reads in a selection report: window 1 or no roll spec at all gives
`<cov>.noroll`, window *w* gives `<cov>.rmean<w>` or `<cov>.rsum<w>`, and lag *t*
gives `<var>.l<t>`.

**One deliberate divergence.** In `select_fe()` the `roll_sum` loop's else branch
fires even for covariates that have a `roll_mean` entry, so `tmax` with
`roll_mean = 3` yields *both* `tmax.noroll` and `tmax.rmean3`. That is correct
there: each derived column is a separate univariable candidate, and only the best
`n_select_uni` per covariate group advances — they compete, they do not co-occur.
This wrapper puts every term into a single formula, so replicating that would put
a variable and its own rolling mean in the same regression as collinear
predictors. Each covariate therefore contributes only the terms its own specs
ask for.

### `offset_scale`

BSC's `pipeline.R` notes population should be divided by a constant (they use
10,000) to help INLA converge. Raw population produces `NAN/INF` values in the
log-likelihood on some windows, so this defaults to 10000. Set to 1 to disable.

### `emit_re_selection_report`

chapkit has **no report entry point** — `ShellModelRunner` takes only
`train_command` and `predict_command`. But it zips the whole train workspace
into an `ml_training_workspace` artifact, so when this flag is on, `train.R` runs
`select_re()` and writes BSC's HTML comparison report into the workspace, where
it is retrievable via the artifact API.

This is also why an HTML-to-PDF conversion is unnecessary: that requirement came
from chap-core's `report` entry point, which chapkit does not have. `select_report()`'s native HTML ships unchanged.

Off by default — it refits many candidate models and costs far more than the
forecast. It does not affect predictions.

**Fixed-effect search is out of scope for this version.** BSC's full workflow is
`select_re()` *then* `select_fe()`; only the random-effect stage is implemented,
which is why the flag is named `emit_re_selection_report` rather than something
that implies both. `select_fe()` ranks covariate configurations — lags, rolling
windows, linearity — and wiring it in raises the unresolved question of whether
this service should run a search at all or stay a single-configuration model.
That decision is pending, so the flag deliberately does not overclaim.

The report's search space comes entirely from the three `report_re_*` fields, for
all three slots, and is independent of the `re_*` fields that pin the forecast.
Turning the spatial term off in the forecast does not narrow the report's search.
Geometry still overrides both: with no adjacency graph a spatial term cannot be
fitted at all.

## Period type

The service declares `period_type=PeriodType.monthly`, so monthly is what CHAP
sends today. GHRmodel itself is not monthly-only — `select_re()` accepts regular
daily, weekly or monthly series — so `prepare_data()` derives `seasonal_id`
according to the detected period: week-of-year for `YYYY-Wnn`, month for
`YYYY-MM`. This matters because `select_re()` fits the seasonal effect with
`cyclic = TRUE`; taking month for weekly data would run a 52-week cycle over 12
levels. Switching `period_type` to weekly therefore needs no change here.

## Example data

`example_data/` is generated from GHRmodel's own bundled `dengue_MS` / `map_MS`
(11 Brazilian microregions, monthly, 2001-2019) by
`tools/make_example_data.R`, renamed into CHAP's column convention.

`dengue_MS` carries no precipitation, so the example uses `mean_temperature` (the
`tmin`/`tmax` midpoint) and `pdsi` (a drought index) rather than relabelling PDSI
as rainfall.

### The fixture does not use the service defaults

Deliberate, and worth understanding before running anything.

The config **defaults** name `rainfall` and `mean_temperature`, because those are
CHAP's standard climate columns and what a real deployment will have. chapkit's
own contract test also keys its synthetic data off the schema default, so the
default has to describe reality rather than this fixture.

The **fixture** has no `rainfall` at all, so `example_data/config.yml` overrides
the covariates to `mean_temperature` + `pdsi`. Always pass that config when
running against the example data — `make test-local` and `make test-api` do.

Running the defaults against the fixture is a hard error naming the missing
covariate, rather than a silent drop — fitting without a term the user asked for
would be a materially different model reported as success:

```
Error: Configured covariate(s) not present in the data: rainfall
  columns supplied: population, mean_temperature, pdsi
  Set additional_continuous_covariates to match your data.
```

## Tests

| Target | What it establishes |
|---|---|
| `make test-unit` | 50 checks over the pure helpers in `scripts/lib.R` |
| `make test-local` | train + predict directly against the fixture |
| `make test-contract` | chapkit's contract test; supplies no geometry, so it also covers the spatial-effect-disabled path |
| `make test-api` | real train and predict jobs over REST with geometry, returning 33 rows x 100 samples |

## Equivalence with BSC's reference pipeline

The selection path was checked against BSC's own `select_re()` reference pipeline
on their Laos dengue dataset, with both priors and the full random-effect search
space matched.

Across the 13 univariable and 7 multivariable candidates, all model IDs are
shared and none is missing on either side. Beyond that the picture splits:

**Structural selection reproduces exactly.** Which random-effect type wins each
slot, and the selected multivariable set (mod07, mod05, mod03), came out the same
in every run. Those comparisons are separated by 5-100 WAIC.

**Prior-variant selection does not reproduce** — in BSC's implementation as much
as here. Two runs of *this wrapper* on identical inputs selected different
spatial priors, and two runs of *BSC's own script* differ by a similar margin.

The reason is that the prior variants are too close together to separate, on two
counts. Selection ranks on WAIC, where only differences between models on the
same data mean anything:

| comparison | WAIC gap | separable |
|---|---|---|
| structural (spatial vs seasonal, rw1 vs rw2, ...) | 5 - 101 | yes |
| prior variant (`prec1` vs `prec2`) | 0.26 - 0.72 | no |

First, the conventional threshold for a meaningful difference in an information
criterion is around 2 — every prior gap is well under it, so the models are
statistically indistinguishable before any question of tooling arises. Second,
the gaps are also inside INLA's own run-to-run variation, measured at 0.607 and
0.235 in two attempts.

Threading is not the cause — INLA is not bit-reproducible even at `nthreads=1`.

**Consequence for users:** treat the report's choice between random-effect
*structures* as meaningful, and its choice between *priors* as arbitrary on data
like this. Widening the prior contrast, or fixing the prior and dropping it from
the search, would make the report's prior ranking mean something.

Not covered: `select_fe()` (the wrapper's report runs `select_re()` only), and
the forecast itself — BSC's pipeline produces no predictions to compare against.

## Forecast skill

Checked by holding out the last 3 months of the `dengue_MS`
fixture and scoring the posterior median against truth. These runs used
`example_data/config.yml` (covariates `mean_temperature` + `pdsi`), **not** the
service defaults — the fixture has no `rainfall`:

| Window | Model | corr | MAE | 90% coverage |
|---|---|---|---|---|
| 2005-2010 | RE only | **0.947** | 31.2 | 100% |
| 2019 | RE only | 0.119 | 83.7 | 100% |
| 2019 | + covariates | 0.133 | 88.9 | 97% |

The wrapper is correct — it reproduces strong skill on the 2005-2010 window. But
**forecast skill varies enormously by window**, and the 2019 horizon is near
unskilled under every configuration tried. Interval coverage stays high because
the intervals are very wide.

This is a property of the model and data, not the wrapper, and it is worth
raising with BSC: an `iid` interannual effect cannot extrapolate to an anomalous
year, and 2019 was a major dengue epidemic year in Brazil. Do not read the
2005-2010 number as a general accuracy claim.

## Platform

**amd64 only.** R-INLA publishes x86_64 Linux binaries only. On arm64 hosts
everything runs under emulation — correct but slow.

Under emulation a spatial (`bym2`) fit also floods the log with
`mbind: Operation not permitted`. Harmless — results are unaffected — and it
comes from INLA's bundled allocator calling a NUMA syscall that qemu does not
implement. No usable workaround: the allocators that stay quiet fail to start
INLA at all.

## Dependencies

`ghcr.io/dhis2-chap/chapkit-r-inla` already ships R 4.5, INLA 25.10.19 and the
spatial stack. The only additions are `cowplot` and `GHRexplore` (both on CRAN —
GHRexplore is v0.2.2) plus
GHRmodel itself, pinned to a commit on the `dhis2-workflow` branch.

## License

[GPL-3.0](LICENSE), matching sister chap-models repos.
