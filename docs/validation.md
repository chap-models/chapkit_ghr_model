# Validation

How the wrapper was checked against BSC's reference pipeline, and how well it forecasts. Back to the [README](../README.md).

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
