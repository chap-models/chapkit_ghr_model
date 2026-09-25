# GHRmodel chapkit service. The chapkit-r-inla base ships R 4.5 + INLA + the
# spatial stack; only cowplot and GHRexplore are missing.
#
# amd64 only -- INLA publishes x86_64 Linux binaries only; arm64 hosts run it
# under emulation.
ARG BASE_PLATFORM=linux/amd64
FROM --platform=${BASE_PLATFORM} ghcr.io/dhis2-chap/chapkit-r-inla:latest

USER root
WORKDIR /work

# The two GHRmodel imports the base lacks, both on CRAN.
RUN R -q -e "install.packages(c('cowplot','GHRexplore'), repos='https://cloud.r-project.org')" \
    && R -q -e "stopifnot(requireNamespace('cowplot'), requireNamespace('GHRexplore'))"

# GHRmodel pinned to a commit for reproducible builds. Clone-then-checkout
# rather than remotes::install_git(ref=<sha>): a bare-SHA `git fetch` is
# rejected unless the server enables uploadpack.allowReachableSHA1InWant.
ARG GHRMODEL_BRANCH=dhis2-workflow
ARG GHRMODEL_REF=b2f433bd7febc921f51f37cd7376e79cb8f12058
RUN git clone --branch "${GHRMODEL_BRANCH}" \
        https://gitlab.earth.bsc.es/ghr/ghrmodel.git /tmp/ghrmodel \
    && git -C /tmp/ghrmodel checkout --quiet "${GHRMODEL_REF}" \
    && R -q -e "install.packages('/tmp/ghrmodel', repos=NULL, type='source')" \
    && R -q -e "library(GHRmodel); stopifnot(all(sapply(c('select_re','select_fe','select_report','fit_models','sample_ppd'), exists)))" \
    && rm -rf /tmp/ghrmodel

# Python deps into the base image's existing venv (--no-dev: the base ships uvicorn).
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    UV_PROJECT_ENVIRONMENT=/app/.venv uv sync --frozen --no-dev --no-install-project

# Commit the image was built from, reported as git_revision on /api/v1/info.
# The publish workflow passes it; locally: --build-arg GIT_REVISION=$(git rev-parse HEAD)
ARG GIT_REVISION=""
ENV GIT_REVISION=${GIT_REVISION}

COPY main.py ./
COPY scripts/ ./scripts/

# The chmod is load-bearing: select_report() renders its Rmd into GHRmodel's
# template dir, so that dir must be writable for the optional report. The base
# image's a+rX on site-library grants no write bit, and GHRmodel is installed
# here rather than in the base.
RUN chmod a+w /usr/local/lib/R/site-library/GHRmodel/templates \
    && groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --create-home app \
    && mkdir -p /work/data \
    && chown app:app /work/data
USER app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl --fail http://localhost:8000/health || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
