# Implementation

How the wrapper drives GHRmodel, and what it does and does not cover. Back to the [README](../README.md).

## Scope

BSC's workflow is a three-stage, human-in-the-loop model *selection* process:
`select_re()` ranks random-effect structures, `select_fe()` ranks covariate
configurations, `select_report()` renders the comparison for a human to read.
Neither `select_*` function returns a fitted model.

This service implements the narrower first step: run a single configuration end
to end. The multi-configuration search is available as an
optional report (see [`emit_re_selection_report`](configuration.md#emit_re_selection_report)) but does not drive the
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
`assign(..., envir = globalenv())` will break it. `ghr/selection_report.R`
does exactly that, with `on.exit()` cleanup so the globals do not leak.

## Layout

```
main.py            chapkit service definition and config schema
MLproject          the same model as an MLproject, generated from main.py by `chapkit mlproject export`
renv.lock          pinned R packages, restored by the Dockerfile and by standalone runs
ghr/               what the runner invokes, and nothing else
  lib.R              shared wrapper helpers
  train.R            train entry point: validate + placeholder (no-op)
  selection_report.R optional RE selection report, sourced only when enabled
  predict.R          predict entry point (fit + posterior draws)
tools/             development tooling, not shipped in the image
  make_example_data.R  regenerates example_data/ from dengue_MS
  api_smoke.py         end-to-end API test, driven by `make test-api`
  test_lib.R           unit checks, driven by `make test-unit`
example_data/      fixtures
docs/              these notes
```

## Dependencies

`renv.lock` pins every R package the scripts use: GHRmodel at a commit on the
`dhis2-workflow` branch, INLA 25.10.19 from the INLA repository, and the rest from
CRAN through Posit Package Manager, which serves Linux binaries. The Dockerfile
restores it on top of `ghcr.io/dhis2-chap/chapkit-r-inla`, which already ships R
4.5, INLA and the spatial stack, so the build mostly adds GHRmodel, `cowplot` and
`GHRexplore`.

To move GHRmodel to another commit, change `RemoteSha` in its `renv.lock` entry
and rebuild.

## Platform

**amd64 only.** R-INLA publishes x86_64 Linux binaries only. On arm64 hosts
everything runs under emulation — correct but slow.

Under emulation a spatial (`bym2`) fit also floods the log with
`mbind: Operation not permitted`. Harmless — results are unaffected — and it
comes from INLA's bundled allocator calling a NUMA syscall that qemu does not
implement. No usable workaround: the allocators that stay quiet fail to start
INLA at all.
