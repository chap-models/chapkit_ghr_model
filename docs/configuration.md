# Configuration

Every option the model takes, and how the wrapper interprets them. Back to the [README](../README.md).

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
[How it works](implementation.md#how-it-works) on why global specifically.

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
