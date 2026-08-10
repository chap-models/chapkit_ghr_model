"""ML service wrapping BSC's GHRmodel (dhis2-workflow branch) for CHAP.

GHRmodel is a Bayesian spatio-temporal model-selection package built on R-INLA,
from the Global Health Resilience group at the Barcelona Supercomputing Center.

Scope: run a *single* model configuration, with every parameter
BSC's workflow lets you select exposed as a config field. The multi-configuration
search their select_re()/select_fe() functions perform is a later iteration.

Design notes:

- Training is a no-op. GHRmodel's selection functions return ranked comparisons,
  not a fitted model, and the forecast needs a model fitted over historic+future
  with the future outcomes blanked. So all fitting happens in predict, matching
  the existing chapkit EWARS model.
- The nested list-valued parameters (roll_mean, roll_sum, lag, nl) are named
  lists of numeric vectors in R. Pydantic could model them as nested objects,
  but the CHAP Modeling App (and chapkit's own console) only render flat scalars,
  enums and scalar arrays as editable form controls -- a nested object drops to
  raw-JSON editing. Keeping the fields editable, they are encoded as strings
  here: "mean_temperature:1,3;rainfall:3". See scripts/lib.R:parse_spec for the parser.
- No GHRmodel source is modified. Everything below drives its exported API.
"""

import os
from pathlib import Path
from typing import Literal

from chapkit import BaseConfig
from chapkit.api import AssessedStatus, MLServiceBuilder, MLServiceInfo, ModelMetadata, PeriodType
from chapkit.artifact import ArtifactHierarchy
from chapkit.ml import ShellModelRunner
from pydantic import Field


class GHRModelConfig(BaseConfig):
    """One GHRmodel configuration, as exposed to CHAP and the Modeling App."""

    prediction_periods: int = Field(
        default=3,
        description="Number of periods to forecast into the future.",
    )

    # ---- Random effects -------------------------------------------------
    # Mirrors select_re()'s re_spatial / re_seasonal / re_interannual, but
    # pinned to one choice each rather than a set to search over. "none" drops
    # the term entirely.
    # Constrained to select_re()'s documented options per slot, which are
    # narrower than write_inla_formulas() would accept. Declaring them as
    # Literal emits a JSON Schema enum, so the Modeling App renders a dropdown
    # and an invalid value is rejected at POST /api/v1/configs rather than
    # failing partway through a prediction job.
    re_spatial: Literal["bym2", "none"] = Field(
        default="bym2",
        description=(
            "How risk varies between areas. 'bym2' (Besag-York-Mollie) lets "
            "neighbouring areas share information via the adjacency graph, plus "
            "an unstructured per-area term; 'none' omits the effect. Requires "
            "geometry, and is forced to 'none' when none is supplied."
        ),
    )
    re_seasonal: Literal["rw1", "rw2", "none"] = Field(
        default="rw1",
        description=(
            "How risk varies within the year, as a cycle (December wraps to "
            "January). 'rw1' is a random walk that smooths the level between "
            "consecutive periods; 'rw2' smooths the slope instead, giving a "
            "gentler, more curved seasonal shape; 'none' omits the effect."
        ),
    )
    re_interannual: Literal["iid", "rw1", "rw2", "none"] = Field(
        default="iid",
        description=(
            "How risk varies between years. 'iid' treats each year as "
            "independent, which handles year-to-year shocks but cannot "
            "extrapolate a trend to an unseen year; 'rw1' and 'rw2' assume "
            "consecutive years are related and carry a trend forward; 'none' "
            "omits the effect."
        ),
    )

    # ---- Priors ---------------------------------------------------------
    # BSC's demo defines two PC priors and searches over both:
    #   prec1 = list(prec = list(prior = "pc.prec", param = c(0.5,  0.01)))
    #   prec2 = list(prec = list(prior = "pc.prec", param = c(1.0,  0.01)))
    # Encoded here as "U:alpha" pairs so a set can be expressed, matching the
    # encoding used for the covariate parameters.
    priors: str = Field(
        default="0.5:0.01",
        description=(
            "How much the random effects are allowed to vary, as penalised-"
            "complexity priors. Each 'U:alpha' pair reads as 'the probability "
            "that this effect's standard deviation exceeds U is alpha', so "
            "'0.5:0.01' says values above 0.5 are unlikely and keeps the effect "
            "conservative. Separate pairs with semicolons. The forecast uses the "
            "first pair; the selection report searches all of them. BSC's Laos "
            "demo uses '0.5:0.01;1:0.01'."
        ),
    )

    # ---- Fixed effects --------------------------------------------------
    # BaseConfig reserves additional_continuous_covariates as a CHAP-interpreted
    # field; it names the climate covariates entering the model.
    additional_continuous_covariates: list[str] = Field(
        default_factory=lambda: ["rainfall", "mean_temperature"],
        description="Continuous covariates to include as fixed effects.",
    )
    roll_mean: str = Field(
        default="mean_temperature:3",
        description=(
            "Rolling-mean windows per covariate, encoded as "
            "'name:w1,w2;name2:w3'. Window 1 means no rolling. "
            "Empty string disables. Matches select_fe()'s roll_mean."
        ),
    )
    roll_sum: str = Field(
        default="rainfall:3",
        description=(
            "Rolling-sum windows per covariate, same encoding as roll_mean. Conventionally used for precipitation."
        ),
    )
    lag: str = Field(
        default="mean_temperature:1;rainfall:1",
        description=(
            "Lags in periods per covariate, same encoding. Lag 0 means no lag. "
            "Multiple values put several lagged terms in the one model."
        ),
    )
    nl: str = Field(
        default="",
        description=(
            "Non-linear (random walk) covariate effects, encoded 'name:n' where "
            "n is the number of basis knots. Empty string means all effects linear."
        ),
    )
    standardize: bool = Field(
        default=True,
        description="Centre and scale covariates before fitting. Aids INLA convergence.",
    )

    # ---- Likelihood and sampling ---------------------------------------
    # Constrained to what the *forecast* path supports, which is narrower than
    # what fit_models() accepts. fit_models() passes family straight to INLA
    # without whitelisting, but sample_ppd() dispatches on it and raises
    # "Unsupported family" for anything else -- so another family would fit
    # successfully and then fail at the sampling step, after the expensive part.
    family: Literal["nbinomial", "poisson"] = Field(
        default="nbinomial",
        description=(
            "INLA likelihood family. 'nbinomial' handles overdispersed counts; "
            "'poisson' assumes mean equals variance. These are the only two "
            "families GHRmodel's posterior sampler supports."
        ),
    )
    offset: str = Field(
        default="population",
        description=(
            "Offset column, entering the linear predictor as log(offset). "
            "Empty string disables. Modelling rates rather than counts."
        ),
    )
    offset_scale: float = Field(
        default=10000.0,
        description=(
            "Divide the offset by this before fitting. BSC's own pipeline notes "
            "population should be divided by a constant (they use 10,000) to help "
            "INLA converge. Set to 1 to disable."
        ),
    )
    n_samples: int = Field(
        default=1000,
        description="Posterior predictive draws per forecast row.",
    )
    nthreads: int = Field(
        default=4,
        description="INLA compute threads.",
    )

    # ---- Selection report ----------------------------------------------
    # chapkit has no report entry point, but it zips the whole train workspace
    # into an ml_training_workspace artifact -- so select_report()'s HTML is
    # retrievable from there. Off by default because it refits many candidate
    # models and is far more expensive than the forecast itself.
    # Named for what it actually does. BSC's full selection workflow is
    # select_re() *then* select_fe(); only the random-effect stage is
    # implemented here, so calling it "selection report" would overclaim.
    # Fixed-effect search is out of scope for this version -- see README.
    emit_re_selection_report: bool = Field(
        default=False,
        description=(
            "Run BSC's select_re() random-effect search during training and save "
            "its HTML comparison report into the training artifact. Covers the "
            "random-effect stage only, not select_fe(). Expensive: fits many "
            "candidate models. Does not affect the forecast."
        ),
    )
    # All three report_re_* fields are search spaces for the report, independent
    # of the single configuration the forecast fits. They are comma-separated
    # rather than Literal because they name sets; validated R-side.
    report_re_spatial: str = Field(
        default="bym2",
        description=(
            "Comma-separated spatial effects for the report search. Forced to 'none' when no geometry is supplied."
        ),
    )
    report_re_seasonal: str = Field(
        default="rw1,rw2",
        description="Comma-separated seasonal effects for the selection report search.",
    )
    report_re_interannual: str = Field(
        default="iid,rw1,rw2",
        description="Comma-separated interannual effects for the selection report search.",
    )


runner: ShellModelRunner[GHRModelConfig] = ShellModelRunner(
    train_command="Rscript scripts/train.R --data {data_file} --geo {geo_file}",
    predict_command=(
        "Rscript scripts/predict.R --historic {historic_file} --future {future_file} "
        "--geo {geo_file} --output {output_file}"
    ),
)

info = MLServiceInfo(
    id="chapkit-ghr-model",
    display_name="GHRmodel (chapkit)",
    version="0.1.0",
    description=(
        "Bayesian hierarchical spatio-temporal model for climate-sensitive disease, "
        "built on R-INLA. Wraps BSC's GHRmodel package (dhis2-workflow branch), running "
        "a single user-specified model configuration with configurable spatial, seasonal "
        "and interannual random effects and lagged/rolling climate covariates."
    ),
    model_metadata=ModelMetadata(
        author="Global Health Resilience group, BSC (wrapped for CHAP by HISP Centre)",
        author_assessed_status=AssessedStatus.red,
        # The wrapper's maintainer, not GHRmodel's. BSC authored the model and are
        # credited above, but support for this service should not route to them --
        # they did not write it and have not signed off on it.
        contact_email="morten@dhis2.org",
        organization="Barcelona Supercomputing Center",
        organization_logo_url="https://www.bsc.es/sites/default/files/public/bscw2/content/about-bsc/bsc-logo.png",
        citation_info=(
            "Lowe R, Lee SA, O'Reilly KM et al. (2021) Combined effects of hydrometeorological "
            "hazards and urbanisation on dengue risk in Brazil: a spatiotemporal modelling study. "
            "The Lancet Planetary Health. https://doi.org/10.1016/S2542-5196(20)30292-8"
        ),
    ),
    period_type=PeriodType.monthly,
    allow_free_additional_continuous_covariates=True,
    required_covariates=["population"],
    min_prediction_periods=1,
    max_prediction_periods=12,
)

HIERARCHY = ArtifactHierarchy(
    name="chapkit_ghr_model",
    level_labels={0: "ml_training_workspace", 1: "ml_prediction"},
)

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///data/chapkit.db")
if DATABASE_URL.startswith("sqlite") and ":///" in DATABASE_URL:
    db_path = Path(DATABASE_URL.split("///")[1])
    db_path.parent.mkdir(parents=True, exist_ok=True)

app = (
    MLServiceBuilder(
        info=info,
        config_schema=GHRModelConfig,
        hierarchy=HIERARCHY,
        runner=runner,
        database_url=DATABASE_URL,
    )
    # CHAP Core registration. Configured entirely by environment:
    #   SERVICEKIT_ORCHESTRATOR_URL  registration endpoint
    #   SERVICEKIT_REGISTRATION_KEY  shared secret, if the instance requires one
    # With no orchestrator URL set, registration is skipped and the service runs
    # normally -- verified healthy without those vars. Note it is not quite
    # silent despite what chapkit's migration guide says: servicekit logs
    # "registration.missing_orchestrator_url" at ERROR and "registration.skipped"
    # at WARNING on every start. Harmless, but expect it in local logs.
    #
    # Omitting this call entirely would mean the service could never register,
    # even when deployed with those vars set.
    .with_registration(keepalive_interval=15)
    .build()
)


if __name__ == "__main__":
    from chapkit.api import run_app

    run_app("main:app", reload=False)
