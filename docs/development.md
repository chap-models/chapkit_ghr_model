# Development

Building, running and testing the service. Back to the [README](../README.md).

## Usage

```bash
make build          # build the image
make run            # run the service on :8000
make test-unit      # unit checks for the helpers in ghr/lib.R
make test-local     # run train.R + predict.R directly against example_data
make test-contract  # chapkit's own contract test (synthetic data, no geo)
make test-api       # train + predict as real API jobs, with real geometry
make test-mlproject # test-contract + test-api against `chapkit mlproject run`
```

Or run the prebuilt image from GHCR (once published):

```bash
docker compose -f compose.ghcr.yml up   # service on :8000
```

## Running from the MLproject

`MLproject` describes the same model for `chapkit mlproject run` and
`chap eval --run-config.as-chapkit`: the same service info, config options and
defaults, and train/predict commands. It is generated from `main.py` by
`chapkit mlproject export`, so `main.py` stays the source of truth: edit it and
run `make mlproject`. `make lint` (and so CI) runs `chapkit mlproject export
--check`, which fails when the file is stale or when `chapkit mlproject run`
would read it as a different service.

Export warns about one setting an MLproject cannot carry: `main.py` registers
with a 15s keepalive. Pass `--keepalive-interval 15` to `chapkit mlproject run`
to keep it when the service registers with chap-core.

The commands need R with the packages in `renv.lock`. The MLproject declares no
environment, because `chapkit mlproject export` cannot write one, so restore
them first as in [the README](../README.md#1-clone-and-restore-the-r-packages). The
service image has them, and has the MLproject in `/work`:

```bash
docker run --rm --platform linux/amd64 -p 8000:8000 \
  ghcr.io/chap-models/chapkit_ghr_model:latest \
  chapkit mlproject run . --host 0.0.0.0 --port 8000
```

`make test-mlproject` does this and runs the contract and API smoke tests against it.
Point `chap eval --model-name http://localhost:8000` at the running service, or
use `chap eval --run-config.as-chapkit` directly on a machine where `renv.lock`
has been restored.

The MLproject sets `meta_data.config_format: flat`, so `chapkit mlproject run`
(chapkit 2.4.0 or later) writes the same flat `config.yml` as `main.py`.
chap-core requires 2.4.0 for `--run-config.as-chapkit` since
dhis2-chap/chap-core#737. Older chapkit, as in chap-core installs from before
that, ignores the key and nests the model options under `user_option_values`;
`read_config()` in `ghr/lib.R` accepts both layouts.

Chap's own MLproject runners (`docker_env` and friends) are not supported:
they write the config under another file name, passed as `{model_config}`,
which the scripts do not read.

## Tests

| Target | What it establishes |
|---|---|
| `make test-unit` | 50 checks over the pure helpers in `ghr/lib.R` |
| `make test-local` | train + predict directly against the fixture |
| `make test-contract` | chapkit's contract test; supplies no geometry, so it also covers the spatial-effect-disabled path |
| `make test-api` | real train and predict jobs over REST with geometry, returning 33 rows x 100 samples |
| `make test-mlproject` | `test-contract` and `test-api` against the service `chapkit mlproject run` builds from `MLproject` |

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
