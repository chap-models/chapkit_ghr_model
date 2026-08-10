"""End-to-end API smoke test: drives train and predict as real jobs.

Exercises the same path CHAP itself uses (POST config, POST $train, poll the
job, POST $predict against the training artifact, download the prediction),
rather than invoking the R scripts directly.

Development tooling, not part of the service image. Driven by `make test-api`.

Usage:
    python3 tools/api_smoke.py [base_url]
"""

import csv
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8128"
EXAMPLE = Path(__file__).resolve().parent.parent / "example_data"


def request(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{BASE}{path}", data=data, method=method, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read().decode()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} on {method} {path}\n{e.read().decode()[:800]}")
        raise


def load_csv(name):
    """Read a fixture into chapkit's {columns, data} DataFrame shape."""
    with open(EXAMPLE / name, newline="") as fh:
        rows = list(csv.reader(fh))
    header, body = rows[0], rows[1:]

    def cell(v):
        if v in ("", "NA"):
            return None
        try:
            return float(v)
        except ValueError:
            return v

    # location must stay a string; everything else is numeric where possible.
    loc = header.index("location")
    out = []
    for r in body:
        out.append([r[i] if i == loc else cell(r[i]) for i in range(len(header))])
    return {"columns": header, "data": out}


def wait_for_job(job_id, label, timeout=3600):
    """Poll until the job leaves a running state."""
    start = time.time()
    last = None
    while time.time() - start < timeout:
        job = request("GET", f"/api/v1/jobs/{job_id}")
        status = job.get("status")
        if status != last:
            print(f"  {label}: {status} ({int(time.time() - start)}s)")
            last = status
        if status in ("completed", "failed", "cancelled"):
            return job
        time.sleep(5)
    raise TimeoutError(f"{label} did not finish within {timeout}s")


def main():
    print(f"Target: {BASE}")
    health = request("GET", "/health")
    print(f"health: {health['status']}")

    geo = json.loads((EXAMPLE / "geo.json").read_text())
    config_data = {
        "prediction_periods": 3,
        "additional_continuous_covariates": ["mean_temperature", "pdsi"],
        "re_spatial": "bym2",
        "re_seasonal": "rw1",
        "re_interannual": "iid",
        "roll_mean": "mean_temperature:3;pdsi:3",
        "roll_sum": "",
        "lag": "mean_temperature:1;pdsi:1",
        "nl": "",
        "offset": "population",
        "offset_scale": 10000,
        "n_samples": 100,
        "nthreads": 4,
        "emit_re_selection_report": False,
    }

    print("\n[1] create config")
    cfg = request("POST", "/api/v1/configs", {"name": "ghrmodel_api_smoke", "data": config_data})
    config_id = cfg["id"]
    print(f"  config_id={config_id}")

    print("\n[2] train")
    train = request(
        "POST",
        "/api/v1/ml/$train",
        {"config_id": config_id, "data": load_csv("training_data.csv"), "geo": geo},
    )
    job = wait_for_job(train["job_id"], "train")
    if job.get("status") != "completed":
        print(f"TRAIN FAILED: {json.dumps(job)[:1500]}")
        return 1
    model_artifact = train["artifact_id"]
    print(f"  model artifact={model_artifact}")

    print("\n[3] predict")
    pred = request(
        "POST",
        "/api/v1/ml/$predict",
        {
            "artifact_id": model_artifact,
            "historic": load_csv("training_data.csv"),
            "future": load_csv("future_data.csv"),
            "geo": geo,
        },
    )
    job = wait_for_job(pred["job_id"], "predict")
    if job.get("status") != "completed":
        print(f"PREDICT FAILED: {json.dumps(job)[:1500]}")
        return 1

    print("\n[4] fetch predictions")
    art = request("GET", f"/api/v1/artifacts/{pred['artifact_id']}")
    # The DataFrame sits under data.content; data itself carries type/metadata.
    content = (art.get("data") or {}).get("content") or {}
    cols = content.get("columns", [])
    rows = content.get("data", [])
    samples = [c for c in cols if c.startswith("sample_")]
    print(f"  rows={len(rows)} columns={len(cols)} sample_columns={len(samples)}")

    ok = bool(rows) and len(samples) == config_data["n_samples"] and {"time_period", "location"} <= set(cols)
    if ok:
        i_t, i_l = cols.index("time_period"), cols.index("location")
        i_s = [cols.index(c) for c in samples]
        r = rows[0]
        vals = sorted(r[i] for i in i_s)
        med = vals[len(vals) // 2]
        print(f"  first row: {r[i_t]} / {r[i_l]} median={med}")
        print("\nAPI SMOKE OK")
        return 0

    print(f"\nAPI SMOKE FAILED (cols={cols[:6]}...)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
