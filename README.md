# GHRmodel (chapkit)

[![CI](https://github.com/chap-models/chapkit_ghr_model/actions/workflows/ci.yml/badge.svg)](https://github.com/chap-models/chapkit_ghr_model/actions/workflows/ci.yml)
[![Docker](https://github.com/chap-models/chapkit_ghr_model/actions/workflows/publish-docker.yml/badge.svg)](https://github.com/chap-models/chapkit_ghr_model/actions/workflows/publish-docker.yml)
[![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

[GHRmodel](https://gitlab.earth.bsc.es/ghr/ghrmodel) (`dhis2-workflow` branch), the
Bayesian hierarchical spatio-temporal model for climate-sensitive disease from the
Global Health Resilience group at the Barcelona Supercomputing Center, wrapped so
that [CHAP](https://github.com/dhis2-chap/chap-core) can train, run and evaluate it.

## What has been done here (in the wrapper)

- **GHRmodel itself is unmodified.** `ghr/train.R` and `ghr/predict.R` are plain R
  scripts that call its exported API (`write_inla_formulas()`, `fit_models()`,
  `sample_ppd()`) to fit **one** model configuration and write posterior samples
  for the forecast periods. Settings come from a `config.yml`.
- **CHAP sees it as a [chapkit](https://github.com/dhis2-chap/chapkit) service.**
  `main.py` and `MLproject` describe its settings and the two commands to run.
- **The R packages are pinned in `renv.lock`**, with GHRmodel at a fixed commit.
  The Docker image is built from the same lockfile.

## Run it yourself

You need x86_64 Linux (INLA ships no other Linux binaries), R 4.5, git and the
system libraries the R packages link against. On Debian or Ubuntu:

```bash
sudo apt-get install git libgdal-dev libgeos-dev libproj-dev libudunits2-dev libuv1-dev
```

### 1. Clone and restore the R packages

Posit Package Manager has prebuilt binaries for Ubuntu, Debian, RHEL and some
other distributions, and renv uses them automatically, so there the restore is
quick. Elsewhere it builds about 90 packages from source, which took around 10
minutes on a typical machine.

```bash
git clone https://github.com/chap-models/chapkit_ghr_model.git
cd chapkit_ghr_model
Rscript -e 'install.packages("renv", repos = "https://cloud.r-project.org")'
Rscript -e 'renv::restore(library = .libPaths()[1], prompt = FALSE)'
```

This installs the locked packages into your first R library. To keep them apart,
point `R_LIBS_USER` at an empty directory first and keep it set.

### 2. Run the model on the example data

`example_data/` is GHRmodel's own `dengue_MS` data (11 Brazilian microregions,
monthly), with the last 3 months held out. From the repository root:

```bash
cp example_data/config.yml config.yml
Rscript ghr/train.R --data example_data/training_data.csv --geo example_data/geo.json
Rscript ghr/predict.R \
  --historic example_data/training_data.csv \
  --future example_data/future_data.csv \
  --geo example_data/geo.json \
  --output predictions.csv
```

`predictions.csv` has one row per location and forecast month, with 200 posterior
samples. Training only validates the inputs; the fit happens in `predict.R`. Edit
`config.yml` to try other settings.

### 3. Evaluate it in CHAP

`chap eval` runs a rolling-origin backtest: it forecasts 3 months ahead from
several cut-off points and scores the forecasts against what was observed.
Install chap-core with [uv](https://docs.astral.sh/uv/) and run, from the
repository root:

```bash
uv tool install chap-core
cp example_data/geo.json example_data/training_data.geojson   # chap eval looks for polygons next to the CSV
chap eval \
  --model-name . \
  --dataset-csv example_data/training_data.csv \
  --model-configuration-yaml example_data/chap_config.yml \
  --backtest-params.n-splits 3 \
  --output-file eval.nc \
  --run-config.as-chapkit
```

This starts the model as a chapkit service and runs the same R scripts with the
packages from step 1. `chap_config.yml` holds the settings of `config.yml` in the
layout CHAP reads. Results go to `eval.nc`; `chap plot-backtest` plots them.

Without R, serve the Docker image with `make run` and, in a second terminal,
point `chap eval` at it:

```bash
chap eval \
  --model-name http://localhost:8000 \
  --dataset-csv example_data/training_data.csv \
  --model-configuration-yaml example_data/chap_config.yml \
  --backtest-params.n-splits 3 \
  --output-file eval.nc \
  --run-config.is-chapkit-model
```

## More detail

- [Configuration](docs/configuration.md): every setting, the random effects, and how the wrapper interprets them
- [Implementation](docs/implementation.md): how the wrapper drives GHRmodel, its scope, and dependencies
- [Validation](docs/validation.md): equivalence with BSC's reference pipeline, and forecast skill
- [Development](docs/development.md): make targets, tests, the MLproject, and the example data

## License

[GPL-3.0](LICENSE)
