"""Generate the MLproject file from main.py, or check that it is up to date.

main.py is the source of truth: the service info, the config schema and the
runner commands. The MLproject repeats all three for `chapkit mlproject run`
(and `chap eval --run-config.as-chapkit`), so it is generated rather than
hand-written and CI fails when the two drift.

    uv run python tools/mlproject.py          # rewrite MLproject
    uv run python tools/mlproject.py --check  # exit 1 if MLproject is stale

--check also parses the file with chapkit's own MLproject reader and compares
the service info, config defaults and runner commands it derives against
main.py, so a generator bug cannot hide behind a matching diff.
"""

import argparse
import difflib
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parent.parent
MLPROJECT = ROOT / "MLproject"

HEADER = """\
# Generated from main.py by tools/mlproject.py -- do not edit by hand.
# Regenerate with `make mlproject`; CI fails when this file is stale.
#
# Runs with `chapkit mlproject run .` or `chap eval --run-config.as-chapkit`.
# No environment is declared: the commands need R with INLA and GHRmodel, which
# the service image provides. See "Running from the MLproject" in README.md.
"""

# chapkit and chap-core add the forecast horizon themselves (prediction_periods,
# prediction_length), so it is not a model option.
RESERVED_OPTIONS = {"prediction_periods"}

# Pydantic schema keys that carry meaning for an MLproject user option. "title"
# is left out: Pydantic derives it from the field name, so it adds nothing.
OPTION_KEYS = ("type", "items", "enum", "default", "description")


def load_main() -> Any:
    sys.path.insert(0, str(ROOT))
    import main

    return main


def mlproject_command(runner_command: str) -> str:
    """Translate a ShellModelRunner command to MLproject placeholders, the inverse of chapkit's mapping."""
    from chapkit.cli.mlproject import RUNNER_PLACEHOLDERS

    for mlproject_param, runner_placeholder in RUNNER_PLACEHOLDERS.items():
        if runner_placeholder.startswith("{"):
            runner_command = runner_command.replace(runner_placeholder, "{" + mlproject_param + "}")
    return runner_command


def entry_point(command: str) -> dict[str, Any]:
    from string import Formatter

    params = [name for _, name, _, _ in Formatter().parse(command) if name]
    return {"parameters": {name: "path" for name in params}, "command": command}


def user_options(config_schema: Any) -> dict[str, Any]:
    properties = config_schema.model_json_schema()["properties"]
    options = {}
    for name, field in config_schema.model_fields.items():
        if name in RESERVED_OPTIONS:
            continue
        option = {key: properties[name][key] for key in OPTION_KEYS if key in properties[name]}
        # default_factory fields have no "default" in the JSON schema.
        option["default"] = field.get_default(call_default_factory=True)
        options[name] = option
    return options


def build(main: Any) -> dict[str, Any]:
    info = main.info
    meta = info.model_metadata
    meta_data = {
        "display_name": info.display_name,
        "description": info.description,
        "author": meta.author,
        "author_note": meta.author_note,
        "author_assessed_status": meta.author_assessed_status.value if meta.author_assessed_status else None,
        "contact_email": meta.contact_email,
        "organization": meta.organization,
        "organization_logo_url": str(meta.organization_logo_url) if meta.organization_logo_url else None,
        "citation_info": meta.citation_info,
        "repository_url": str(meta.repository_url) if meta.repository_url else None,
        "documentation_url": str(meta.documentation_url) if meta.documentation_url else None,
    }
    return {
        "name": main.HIERARCHY.name,
        "version": info.version,
        "target": info.target,
        "supported_period_type": {"monthly": "month", "weekly": "week"}.get(info.period_type.value, "any"),
        "required_covariates": list(info.required_covariates),
        "allow_free_additional_continuous_covariates": info.allow_free_additional_continuous_covariates,
        "requires_geo": info.requires_geo,
        "min_prediction_periods": info.min_prediction_periods,
        "max_prediction_periods": info.max_prediction_periods,
        "meta_data": {key: value for key, value in meta_data.items() if value is not None},
        "user_options": user_options(main.GHRModelConfig),
        "entry_points": {
            "train": entry_point(mlproject_command(main.runner.train_command)),
            "predict": entry_point(mlproject_command(main.runner.predict_command)),
        },
    }


def render(main: Any) -> str:
    body = yaml.safe_dump(build(main), sort_keys=False, allow_unicode=True, width=100)
    return HEADER + "\n" + body


def semantic_problems(main: Any) -> list[str]:
    """Read MLproject the way `chapkit mlproject run` does and compare the result with main.py."""
    from chapkit.cli.mlproject import (
        build_config_schema,
        build_ml_service_info,
        parse_mlproject,
        translate_to_runner_template,
    )

    problems: list[str] = []
    issues: list[str] = []
    mlproject = parse_mlproject(MLPROJECT)
    problems += [f"chapkit warning: {w}" for w in mlproject.parse_warnings]

    served = build_ml_service_info(mlproject, issues).model_dump(mode="json")
    expected = main.info.model_dump(mode="json")
    for key in sorted(set(served) | set(expected)):
        if served.get(key) != expected.get(key):
            problems.append(f"info.{key}: MLproject gives {served.get(key)!r}, main.py has {expected.get(key)!r}")

    generated = build_config_schema(mlproject, issues)().model_dump()
    defaults = main.GHRModelConfig().model_dump()
    for key in sorted(set(generated) | set(defaults)):
        if generated.get(key) != defaults.get(key):
            problems.append(
                f"config.{key}: MLproject default {generated.get(key)!r}, main.py default {defaults.get(key)!r}"
            )

    for name in ("train", "predict"):
        command = translate_to_runner_template(mlproject.entry_points[name].command)
        runner_command = getattr(main.runner, f"{name}_command")
        if command != runner_command:
            problems.append(f"{name} command: MLproject runs {command!r}, main.py runs {runner_command!r}")

    problems += [f"chapkit warning: {issue}" for issue in issues]
    return problems


def main_cli() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if MLproject is stale instead of rewriting it")
    args = parser.parse_args()

    main = load_main()
    wanted = render(main)

    if not args.check:
        MLPROJECT.write_text(wanted)
        print(f"Wrote {MLPROJECT.relative_to(ROOT)}")
        return 0

    current = MLPROJECT.read_text() if MLPROJECT.exists() else ""
    if current != wanted:
        sys.stdout.writelines(
            difflib.unified_diff(current.splitlines(True), wanted.splitlines(True), "MLproject", "generated")
        )
        print("\nMLproject is out of date with main.py; run `make mlproject`.")
        return 1
    problems = semantic_problems(main)
    if problems:
        print("MLproject does not match main.py as chapkit reads it:")
        print("\n".join(f"  - {p}" for p in problems))
        return 1
    print("MLproject is up to date with main.py")
    return 0


if __name__ == "__main__":
    sys.exit(main_cli())
