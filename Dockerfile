# GHRmodel chapkit service. The chapkit-r-inla base ships R 4.5, INLA, renv
# and the spatial stack's system libraries.
#
# amd64 only -- INLA publishes x86_64 Linux binaries only; arm64 hosts run it
# under emulation.
ARG BASE_PLATFORM=linux/amd64
FROM --platform=${BASE_PLATFORM} ghcr.io/dhis2-chap/chapkit-r-inla:latest

USER root
WORKDIR /work

# The R packages, GHRmodel included (pinned to a commit), come from renv.lock,
# the same lockfile a standalone run restores. The project is not activated, so
# restore installs into the site library, and packages the base already has at
# the locked version are left alone.
COPY renv.lock ./
RUN R -q -e "renv::restore(library = .libPaths()[1], prompt = FALSE)" \
    && R -q -e "library(GHRmodel); stopifnot(all(sapply(c('select_re','select_fe','select_report','fit_models','sample_ppd'), exists)))"

# Python deps into the base image's existing venv (--no-dev: the base ships uvicorn).
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    UV_PROJECT_ENVIRONMENT=/app/.venv uv sync --frozen --no-dev --no-install-project

# Commit the image was built from, reported as git_revision on /api/v1/info.
# The publish workflow passes it; locally: --build-arg GIT_REVISION=$(git rev-parse HEAD)
ARG GIT_REVISION=""
ENV GIT_REVISION=${GIT_REVISION}

COPY main.py MLproject ./
COPY ghr/ ./ghr/

# The two chmods are load-bearing: INLA's binaries ship 0744 (predict fails with
# "inla.mkl.run: Permission denied" without a+rX), and select_report() renders
# its Rmd into GHRmodel's template dir, which must be writable for the optional
# report.
RUN chmod -R a+rX /usr/local/lib/R/site-library/INLA/bin \
    && chmod a+w /usr/local/lib/R/site-library/GHRmodel/templates \
    && groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --create-home app \
    && mkdir -p /work/data \
    && chown app:app /work/data
USER app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl --fail http://localhost:8000/health || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
