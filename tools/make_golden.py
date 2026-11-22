"""Write the Python pipeline's outputs as golden JSON for the JS port's parity tests.

Usage:  I20_TODAY=2026-10-25 uv run tools/make_golden.py
Writes tests/golden/{data,fuel,performance,tables,fills}.json (gitignored: personal data).
"""
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import pandas as pd  # noqa: E402

import fuel  # noqa: E402
import insights  # noqa: E402
import performance  # noqa: E402

OUT = ROOT / "tests" / "golden"
POINTS_HEAD = 500


def iso(o):
    """Like insights.clean, but timestamps become YYYY-MM-DDTHH:MM:SS and dates YYYY-MM-DD."""
    if isinstance(o, dict):
        return {k: iso(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [iso(v) for v in o]
    if o is pd.NaT:
        return None
    if isinstance(o, pd.Timestamp):
        return o.strftime("%Y-%m-%dT%H:%M:%S")
    if hasattr(o, "isoformat") and not isinstance(o, str):  # datetime.date
        return o.isoformat()
    return o


def write(name: str, data) -> None:
    data = insights.clean(iso(data))
    path = OUT / f"{name}.json"
    path.write_text(json.dumps(data, allow_nan=False, separators=(",", ":")))
    print(f"Wrote {path.relative_to(ROOT)} ({path.stat().st_size / 1e6:.2f} MB)")


def rows(df: pd.DataFrame) -> list[dict]:
    return df.to_dict("records")


def main() -> None:
    if not os.environ.get("I20_TODAY"):
        sys.exit("Set I20_TODAY (e.g. 2026-10-25) so the golden files are reproducible.")
    OUT.mkdir(parents=True, exist_ok=True)

    trips, points, snaps = insights.load()
    odo_rows = snaps.dropna(subset=["odometer_km"])
    odo = float(odo_rows.odometer_km.iloc[-1]) if len(odo_rows) else float(trips.distance_km.sum())
    fuel_data = fuel.build(trips, odo, snaps)
    delta = fuel_data["calibration"]["delta"] if fuel_data else 0.0

    # Tables first: insights.build adds from_place/to_place to `trips` in place, so snapshot now.
    head = points.head(POINTS_HEAD).copy()
    # `t` is spread fractionally across the gap between breadcrumb timestamps: keep milliseconds.
    head["t"] = head["t"].dt.strftime("%Y-%m-%dT%H:%M:%S.") + (head["t"].dt.microsecond // 1000).astype(str).str.zfill(3)
    tables = {"trips": rows(trips), "snaps": rows(snaps), "points_head": rows(head)}

    data = insights.build(trips, points, snaps, delta)
    if fuel_data:
        data["tank"] = fuel_data["tank"]
        data["fuel_rs_per_km"] = fuel_data["totals"]["rs_per_km_model"]
    perf = performance.build(trips, points, odo, delta, fuel_data["model"] if fuel_data else None)

    write("tables", tables)
    write("data", data)
    write("performance", perf)
    if fuel_data:
        write("fuel", fuel_data)
        csv = fuel.find_csv()
        write("fills", rows(fuel.place_fills(trips, fuel.load_fills(csv), odo, delta)))


if __name__ == "__main__":
    main()
