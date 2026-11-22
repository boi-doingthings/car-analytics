"""Rebuild data/bluelink.db from the raw JSON archive in data/raw/.

Always a full rebuild: raw JSON is the source of truth, the DB is disposable.

Usage:  uv run build_db.py
"""

import datetime as dt
import json
import sqlite3
from pathlib import Path

ROOT = Path(__file__).parent
RAW = ROOT / "data" / "raw"
DB = ROOT / "data" / "bluelink.db"

SCHEMA = """
CREATE TABLE days (
    vehicle_id TEXT, day TEXT, trip_count INT, distance_km REAL, drive_min REAL,
    idle_min REAL, avg_kmh REAL, max_kmh REAL,
    PRIMARY KEY (vehicle_id, day)
);
CREATE TABLE trips (
    vehicle_id TEXT, trip_id TEXT, day TEXT, start_ts TEXT, end_ts TEXT,
    distance_km REAL, drive_min REAL, idle_min REAL, avg_kmh REAL, max_kmh REAL,
    hard_brake INT, rapid_accel INT, overspeed INT,
    start_lat REAL, start_lon REAL, end_lat REAL, end_lon REAL,
    gps_points INT, has_route INT,
    PRIMARY KEY (vehicle_id, trip_id)
);
CREATE TABLE trip_points (
    vehicle_id TEXT, trip_id TEXT, seq INT, ts TEXT, lat REAL, lon REAL
);
CREATE INDEX trip_points_trip ON trip_points (vehicle_id, trip_id);
CREATE TABLE snapshots (
    vehicle_id TEXT, taken_at TEXT, status_time TEXT, odometer_km REAL,
    fuel_pct REAL, range_km REAL, low_fuel INT, door_lock INT, engine_on INT,
    battery_state INT, park_lat REAL, park_lon REAL, park_time TEXT
);
"""


def ts(s: str | None) -> str | None:
    """'20260701085005' -> '2026-07-01 08:50:05'"""
    if not s or len(s) < 14:
        return None
    return f"{s[0:4]}-{s[4:6]}-{s[6:8]} {s[8:10]}:{s[10:12]}:{s[12:14]}"


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def build_days(con) -> int:
    n = 0
    for f in sorted((RAW / "days").glob("*/*.json")):
        for d in (load(f).get("resMsg") or {}).get("dayTripList", []):
            con.execute("INSERT OR REPLACE INTO days VALUES (?,?,?,?,?,?,?,?)", (
                f.parent.name, f"{d['tripDay'][:4]}-{d['tripDay'][4:6]}-{d['tripDay'][6:]}",
                d.get("dayTripCnt"), d.get("tripDist"), d.get("tripDrvTime"),
                d.get("tripIdleTime"), d.get("tripAvgSpeed"), d.get("tripMaxSpeed"),
            ))
            n += 1
    return n


def build_trips(con) -> int:
    n = 0
    for f in sorted((RAW / "trips").glob("*/*.json")):
        vid = f.parent.name
        t = (load(f).get("resMsg") or {}).get("tripInfo")
        if not t:
            continue
        points = t.get("tripList") or []
        # Hyundai purges routes after ~3 months and stamps the current parking
        # spot on start/end, so coords are only trustworthy alongside a route.
        has_route = len(points) > 1
        start, end = t.get("tripStartCoord") or {}, t.get("tripEndCoord") or {}
        trip_id = t["tripStartTime"]
        con.execute("INSERT OR REPLACE INTO trips VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            vid, trip_id, ts(t["tripStartTime"])[:10], ts(t["tripStartTime"]), ts(t.get("tripEndTime")),
            t.get("tripDist"), t.get("tripDrvTime"), t.get("tripIdleTime"),
            t.get("tripAvgSpeed"), t.get("tripMaxSpeed"),
            t.get("tripHardBreakingTime"), t.get("tripRapidAccelationTime"), t.get("tripExcessiveSpeedTime"),
            start.get("lat") if has_route else None, start.get("lon") if has_route else None,
            end.get("lat") if has_route else None, end.get("lon") if has_route else None,
            len(points), int(has_route),
        ))
        if has_route:
            day = dt.datetime.strptime(t["tripStartTime"][:8], "%Y%m%d")
            prev = None
            rows = []
            for i, p in enumerate(points):
                clock = dt.datetime.strptime(p["tripTime"], "%H%M%S").time()
                if prev and clock < prev:  # trip crossed midnight
                    day += dt.timedelta(days=1)
                prev = clock
                rows.append((vid, trip_id, i, dt.datetime.combine(day, clock).isoformat(" "), p["lat"], p["lon"]))
            con.executemany("INSERT INTO trip_points VALUES (?,?,?,?,?,?)", rows)
        n += 1
    return n


def build_snapshots(con) -> int:
    n = 0
    for snap in sorted((RAW / "snapshots").glob("*/*")):
        def part(name):
            p = snap / f"{name}.json"
            return (load(p).get("resMsg") or {}) if p.exists() else {}
        status, loc, maint = part("status_latest"), part("location_park"), part("maintenance_alert")
        coord = loc.get("coord") or {}
        taken = dt.datetime.strptime(snap.name, "%Y%m%dT%H%M%S").isoformat(" ")
        con.execute("INSERT INTO snapshots VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            snap.parent.name, taken, ts(status.get("time")), maint.get("odometer"),
            status.get("fuelLevel"), (status.get("dte") or {}).get("value"),
            int(bool(status.get("lowFuelLight"))) if status else None,
            int(bool(status.get("doorLock"))) if status else None,
            int(bool(status.get("engine"))) if status else None,
            (status.get("battery") or {}).get("batState"),
            coord.get("lat"), coord.get("lon"), ts(loc.get("time")),
        ))
        n += 1
    return n


def main() -> None:
    tmp = DB.with_suffix(".tmp")
    tmp.unlink(missing_ok=True)
    con = sqlite3.connect(tmp)
    con.executescript(SCHEMA)
    counts = {"days": build_days(con), "trips": build_trips(con), "snapshots": build_snapshots(con)}
    con.commit()
    con.close()
    tmp.replace(DB)
    print(f"Built {DB.relative_to(ROOT)}: {counts}")


if __name__ == "__main__":
    main()
