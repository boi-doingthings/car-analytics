"""Turn data/bluelink.db into web/data.json: aggregates, routes and plain-English findings.

Usage:  uv run insights.py
"""

import datetime as dt
import json
import os
import sqlite3
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).parent
DB = ROOT / "data" / "bluelink.db"
RAW = ROOT / "data" / "raw"
OUT = ROOT / "web" / "data.json"

TANK_L = 37
CELL = 0.0015  # ~150 m grid for places
SLOW_KMH = 8
WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


# ---------- loading ----------

def today() -> dt.date:
    """Today, or I20_TODAY (YYYY-MM-DD) when set, so oracle outputs are reproducible."""
    return dt.date.fromisoformat(os.environ["I20_TODAY"]) if os.environ.get("I20_TODAY") else dt.date.today()


def load():
    con = sqlite3.connect(DB)
    trips = pd.read_sql("SELECT * FROM trips ORDER BY start_ts", con, parse_dates=["start_ts", "end_ts"])
    points = pd.read_sql("SELECT * FROM trip_points", con, parse_dates=["ts"])
    snaps = pd.read_sql("SELECT * FROM snapshots ORDER BY taken_at", con, parse_dates=["taken_at", "status_time", "park_time"])
    con.close()
    trips["date"] = trips.start_ts.dt.date
    trips["total_min"] = trips.drive_min + trips.idle_min  # Hyundai's drive time excludes idling
    trips["elapsed_min"] = (trips.end_ts - trips.start_ts).dt.total_seconds() / 60
    return trips, points_with_speed(points), snaps


def latest_raw(name: str) -> dict:
    files = sorted(RAW.glob(f"snapshots/*/*/{name}.json"))
    return (json.loads(files[-1].read_text()).get("resMsg") or {}) if files else {}


def haversine_km(lat1, lon1, lat2, lon2):
    lat1, lon1, lat2, lon2 = map(np.radians, (lat1, lon1, lat2, lon2))
    a = np.sin((lat2 - lat1) / 2) ** 2 + np.cos(lat1) * np.cos(lat2) * np.sin((lon2 - lon1) / 2) ** 2
    return 6371 * 2 * np.arcsin(np.sqrt(a))


def points_with_speed(points: pd.DataFrame) -> pd.DataFrame:
    """Breadcrumbs come ~6 per minute sharing one timestamp; spread them evenly
    across the gap to the next timestamp, then derive a smoothed speed."""
    if points.empty:
        return points.assign(t=pd.Series(dtype="datetime64[ns]"), speed=pd.Series(dtype=float))
    p = points.sort_values(["trip_id", "seq"]).reset_index(drop=True)
    grp = p.groupby(["trip_id", "ts"])
    k = grp.cumcount()
    n = grp["seq"].transform("size")
    firsts = p.drop_duplicates(["trip_id", "ts"])[["trip_id", "ts"]].copy()
    firsts["next_ts"] = firsts.groupby("trip_id")["ts"].shift(-1)
    p = p.merge(firsts, on=["trip_id", "ts"], how="left")
    gap = (p.next_ts - p.ts).dt.total_seconds().fillna(60).clip(lower=1)
    p["t"] = p.ts + pd.to_timedelta(k / n * gap, unit="s")
    prev = p.groupby("trip_id")[["lat", "lon", "t"]].shift()
    d_km = haversine_km(prev.lat, prev.lon, p.lat, p.lon)
    d_h = (p.t - prev.t).dt.total_seconds() / 3600
    raw = (d_km / d_h.where(d_h > 0)).clip(upper=160).fillna(0)
    p["speed"] = raw.groupby(p.trip_id).transform(lambda s: s.rolling(5, min_periods=1, center=True).median())
    return p.drop(columns=["next_ts"])


# ---------- places ----------

def cell_of(lat, lon):
    return (lat / CELL).round().astype("Int64").astype(str) + ":" + (lon / CELL).round().astype("Int64").astype(str)


def find_places(routed: pd.DataFrame) -> pd.DataFrame:
    ends = pd.concat([
        routed[["start_lat", "start_lon", "start_ts"]].set_axis(["lat", "lon", "ts"], axis=1).assign(kind="start"),
        routed[["end_lat", "end_lon", "end_ts"]].set_axis(["lat", "lon", "ts"], axis=1).assign(kind="end"),
    ])
    ends["cell"] = cell_of(ends.lat, ends.lon)
    agg = ends.groupby("cell").agg(lat=("lat", "mean"), lon=("lon", "mean"), visits=("ts", "size")).reset_index()
    last = routed.sort_values("end_ts").groupby("date").tail(1)
    home = cell_of(last.end_lat, last.end_lon).mode()
    home = home.iat[0] if len(home) else None
    wd = ends[(ends.kind == "end") & (ends.ts.dt.dayofweek < 5) & ends.ts.dt.hour.between(7, 11) & (ends.cell != home)]
    work = wd.cell.mode().iat[0] if len(wd) else None
    agg = agg.sort_values("visits", ascending=False).reset_index(drop=True)
    names, i = [], 1
    for c, visits in zip(agg.cell, agg.visits):
        if c == home:
            names.append("Home")
        elif c == work:
            names.append("Work")
        elif visits >= 6:  # only places you return to are worth naming
            names.append(f"Place {i}")
            i += 1
        else:
            names.append(None)
    agg["name"] = names
    return agg[agg.name.notna()].reset_index(drop=True)


def nearest_place(lat, lon, places: pd.DataFrame, within_km=0.35):
    if pd.isna(lat) or places.empty:
        return None
    d = haversine_km(lat, lon, places.lat.values, places.lon.values)
    i = int(np.argmin(d))
    return places.name.iat[i] if d[i] <= within_km else None


# ---------- findings ----------

def fmt_min(m: float) -> str:
    m = round(m)
    return f"{m // 60} h {m % 60} min" if m >= 60 else f"{m} min"


def clock(h: float, suffix: bool = True) -> str:
    hh, mm = int(h), int(round((h % 1) * 60))
    return f"{hh % 12 or 12}:{mm:02d}" + (f" {'am' if hh < 12 else 'pm'}" if suffix else "")


def half_hour(h: float) -> str:
    """'8:30–9:00 am' for the half hour starting at h."""
    same = (h < 12) == (h + 0.5 < 12)
    return f"{clock(h, suffix=not same)}–{clock(h + 0.5)}"


def commute_finding(df: pd.DataFrame, direction: str) -> str | None:
    """Best vs worst half-hour departure slot (needs >=3 trips per slot)."""
    if len(df) < 8:
        return None
    hours = df.start_ts.dt.hour + df.start_ts.dt.minute / 60
    slot = np.floor(hours * 2) / 2
    g = df.assign(slot=slot).groupby("slot").elapsed_min.agg(["median", "size"])
    g = g[g["size"] >= 3]
    if len(g) < 2:
        return None
    best, worst = g["median"].idxmin(), g["median"].idxmax()
    saved = g.loc[worst, "median"] - g.loc[best, "median"]
    if saved < 4:
        return f"Your {direction} takes about the same time whenever you leave."
    return (f"Leave at {half_hour(best)} and your {direction} takes {g.loc[best, 'median']:.0f} min. "
            f"At {half_hour(worst)}, it's {g.loc[worst, 'median']:.0f}.")


def hotspots(points: pd.DataFrame, routed: pd.DataFrame, places: pd.DataFrame) -> list[dict]:
    """Where the car crawls: time spent under SLOW_KMH per ~200 m cell, ignoring
    the first/last minute of each trip and anything near a known place (parking)."""
    if points.empty:
        return []
    p = points.merge(routed[["trip_id", "start_ts", "end_ts"]], on="trip_id")
    p = p[(p.t > p.start_ts + pd.Timedelta(seconds=60)) & (p.t < p.end_ts - pd.Timedelta(seconds=60))]
    p = p.sort_values(["trip_id", "t"])
    p["dt"] = p.groupby("trip_id").t.diff().dt.total_seconds().clip(upper=30).fillna(0)
    slow = p[p.speed < SLOW_KMH].copy()
    if slow.empty:
        return []
    named = places[places.visits >= 3]
    if len(named):
        d = haversine_km(slow.lat.values[:, None], slow.lon.values[:, None], named.lat.values[None, :], named.lon.values[None, :])
        slow = slow[d.min(axis=1) > 0.25]
    slow["cell"] = (slow.lat / 0.002).round().astype(int).astype(str) + ":" + (slow.lon / 0.002).round().astype(int).astype(str)
    g = slow.groupby("cell").agg(lat=("lat", "mean"), lon=("lon", "mean"), seconds=("dt", "sum"),
                                 trips=("trip_id", "nunique")).reset_index()
    g = g[g.trips >= 3].sort_values("seconds", ascending=False).head(8)
    return [{"lat": round(r.lat, 5), "lon": round(r.lon, 5), "minutes": round(r.seconds / 60),
             "trips": int(r.trips), "per_trip": round(r.seconds / 60 / r.trips, 1)} for r in g.itertuples()]


def add_months(d: dt.date, months: int) -> dt.date:
    y, m = divmod(d.month - 1 + months, 12)
    return dt.date(d.year + y, m + 1, min(d.day, 28))


def load_services() -> list[dict]:
    """Workshop visits from service_log.json (hand-maintained), oldest first."""
    try:
        return sorted(json.loads((ROOT / "service_log.json").read_text())["services"], key=lambda s: s["date"])
    except (OSError, ValueError, KeyError):
        return []


def service_plan(odo: float, reg: dt.date | None, pace: float, today: dt.date, services: list[dict]) -> list[dict]:
    """Next due date per Bluelink maintenance item. Items replaced at a logged service count from
    that visit; the rest assume the schedule was kept (every interval from 0 km / registration)."""
    rows = []
    for item in latest_raw("maintenance_alert").get("mainList", []):
        every_km = (item.get("items") or {}).get("distValue") or 0
        every_mo = (item.get("items") or {}).get("termValue") or 0
        if not every_km:
            continue
        done = [s for s in services if any(item["itemId"] in p.get("resets", []) for p in s["parts"])]
        last = done[-1] if done else None
        time_date = None
        if last:
            km_due = last["odometer_km"] + every_km
            if every_mo:
                time_date = add_months(dt.date.fromisoformat(last["date"]), every_mo)
        else:
            km_due = (odo // every_km + 1) * every_km
            if every_mo and reg:
                n = 1
                while add_months(reg, every_mo * n) <= today:
                    n += 1
                time_date = add_months(reg, every_mo * n)
        km_date = today + dt.timedelta(days=(km_due - odo) / pace) if pace else None
        by_time = time_date is not None and (km_date is None or time_date < km_date)
        due = time_date if by_time else km_date
        rows.append({"item": item["itemId"], "every_km": every_km, "every_months": every_mo,
                     "due": due.isoformat() if due else None, "days_left": (due - today).days if due else None,
                     "trigger": "time" if by_time else "distance", "km_due": km_due,
                     "last_done": {"date": last["date"], "km": last["odometer_km"]} if last else None})
    return sorted(rows, key=lambda r: r["days_left"] if r["days_left"] is not None else 1e9)


# ---------- main ----------

def build(trips: pd.DataFrame, points: pd.DataFrame, snaps: pd.DataFrame, delta: float = 0.0) -> dict:
    """Overview data. Adds from_place/to_place to `trips` in place (the other pages reuse them).
    `delta` is the per-trip distance Bluelink drops by rounding down (see fuel.calibrate)."""
    today_date = today()
    services = load_services()
    routed = trips[trips.has_route == 1]
    places = find_places(routed) if len(routed) else pd.DataFrame(columns=["cell", "lat", "lon", "visits", "name"])
    trips["from_place"] = [nearest_place(a, b, places) for a, b in zip(trips.start_lat, trips.start_lon)]
    trips["to_place"] = [nearest_place(a, b, places) for a, b in zip(trips.end_lat, trips.end_lon)]
    routed = trips[trips.has_route == 1]

    vehicle = (latest_raw("vehicles").get("vehicles") or [{}])[0]
    reg = dt.date.fromisoformat(vehicle["regDate"][:10]) if vehicle.get("regDate") else None
    last = snaps.iloc[-1] if len(snaps) else None
    odo = float(last.odometer_km) if last is not None and pd.notna(last.odometer_km) else float(trips.distance_km.sum())
    recent = trips[trips.date > today_date - dt.timedelta(days=90)]
    pace = recent.distance_km.sum() / 90

    km = trips.distance_km.sum() + delta * len(trips)
    total_h = trips.total_min.sum() / 60
    idle_share = trips.idle_min.sum() / trips.total_min.sum()

    # rhythm
    trips["wd"] = trips.start_ts.dt.dayofweek
    trips["hr"] = trips.start_ts.dt.hour
    weeks = max((trips.date.max() - trips.date.min()).days / 7, 1)
    by_wd = trips.groupby("wd").distance_km.sum().reindex(range(7), fill_value=0) / weeks
    rhythm = trips.groupby(["wd", "hr"]).size().unstack(fill_value=0).reindex(index=range(7), columns=range(24), fill_value=0)
    top_wd = int(by_wd.idxmax())
    weekday_avg = by_wd.drop(top_wd).mean()

    # commute
    to_work = routed[(routed.from_place == "Home") & (routed.to_place == "Work")]
    to_home = routed[(routed.from_place == "Work") & (routed.to_place == "Home")]

    # idle by hour
    hr_idle = trips.groupby("hr").agg(idle=("idle_min", "sum"), total=("total_min", "sum"), n=("trip_id", "size"))
    hr_idle = hr_idle[hr_idle.n >= 3]
    hr_idle["share"] = hr_idle.idle / hr_idle.total
    worst_hr = int(hr_idle.share.idxmax()) if len(hr_idle) else None

    hs = hotspots(points, routed, places)
    month = trips.assign(m=pd.to_datetime(trips.date).dt.to_period("M").astype(str)).groupby("m").agg(
        km=("distance_km", "sum"), trips=("trip_id", "size"), drive=("drive_min", "sum"), idle=("idle_min", "sum")).reset_index()
    best_month = month.loc[month.km.idxmax()]
    longest = trips.loc[trips.distance_km.idxmax()]
    short_share = (trips.distance_km < 3).mean()
    events = int(trips.hard_brake.sum() + trips.rapid_accel.sum() + trips.overspeed.sum())

    findings = {
        "hero": f"Since {reg:%-d %B %Y}, your i20 has covered {odo:,.0f} km." if reg else f"Your i20 has covered {odo:,.0f} km.",
        "year": f"{pd.Period(best_month.m).strftime('%B')} was your biggest month at {best_month.km:,.0f} km. "
                f"Your longest drive was {longest.distance_km:.0f} km on {longest.start_ts:%-d %B}.",
        "rhythm": f"{WEEKDAYS[top_wd]}s are your big days: {by_wd[top_wd]:.0f} km on average, "
                  f"against {weekday_avg:.0f} km on the other days.",
        "traffic": f"You spend {idle_share:.0%} of your time in the car standing still with the engine running: "
                   f"{trips.idle_min.sum() / 60:.0f} hours so far"
                   + (f". It's worst on trips that start around {clock(worst_hr)}." if worst_hr is not None else "."),
        "hotspots": (f"You've lost {sum(h['minutes'] for h in hs[:5]) / 60:.1f} hours crawling through these five spots."
                     if len(hs) >= 5 else "Not enough routed trips to find hotspots yet."),
        "commute_to_work": commute_finding(to_work, "drive to work"),
        "commute_to_home": commute_finding(to_home, "drive home"),
        "style": (f"{events} flagged events in {km:,.0f} km. That's one every {km / events:,.0f} km."
                  if events else f"Not one harsh brake, hard launch or speeding alert in {km:,.0f} km."),
        "short": f"{short_share:.0%} of your trips are under 3 km. Those are the costliest kilometres you drive: "
                 "a cold engine burns noticeably more fuel.",
    }

    route_json = {}
    for tid, g in points.groupby("trip_id"):
        t0 = g.t.iloc[0]
        route_json[tid] = [[round(a, 5), round(b, 5), round(s), int((t - t0).total_seconds())]
                           for a, b, s, t in zip(g.lat, g.lon, g.speed, g.t)]

    # Reconstruct when the odometer crossed 10,000 km steps (first service milestones).
    daily_km = trips.groupby("date").distance_km.sum().sort_index()
    odo_by_day = odo - daily_km[::-1].cumsum()[::-1].shift(-1, fill_value=0)
    milestones = []
    for mark in range(10000, int(odo) + 1, 10000):
        crossed = odo_by_day[odo_by_day >= mark]
        if len(crossed):
            milestones.append({"km": mark, "date": str(crossed.index[0])})

    snap_rows = snaps.dropna(subset=["fuel_pct"])
    return {
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "vehicle": {"model": vehicle.get("vehicleName", "i20"), "reg_date": reg.isoformat() if reg else None,
                    "year": vehicle.get("year")},
        "status": None if last is None else {
            "odometer": odo, "fuel_pct": last.fuel_pct, "fuel_l": round(last.fuel_pct / 100 * TANK_L),
            "range_km": last.range_km, "locked": bool(last.door_lock), "low_fuel": bool(last.low_fuel),
            "as_of": last.status_time.isoformat() if pd.notna(last.status_time) else None,
            "park": [last.park_lat, last.park_lon] if pd.notna(last.park_lat) else None,
        },
        "totals": {"km": km, "trips": len(trips), "days_driven": int(trips.date.nunique()),
                   "hours": total_h, "idle_hours": trips.idle_min.sum() / 60, "idle_share": idle_share,
                   "moving_kmh": km / (trips.drive_min.sum() / 60), "top_kmh": trips.max_kmh.max(),
                   "coverage": km / odo if odo else None, "pace_90d": pace,
                   "first_day": str(trips.date.min()), "last_day": str(trips.date.max()),
                   "routed_trips": int(len(routed)), "short_share": short_share,
                   "hard_brake": int(trips.hard_brake.sum()), "rapid_accel": int(trips.rapid_accel.sum()),
                   "overspeed": int(trips.overspeed.sum())},
        "findings": findings,
        "days": [[str(d), round(g.distance_km.sum(), 1), len(g)] for d, g in trips.groupby("date")],
        "months": [[r.m, round(r.km), int(r.trips), round(r.km / (r.drive / 60), 1) if r.drive else 0] for r in month.itertuples()],
        "rhythm": rhythm.values.tolist(),
        "weekday_km": [round(v, 1) for v in by_wd],
        "idle_by_hour": [[int(h), round(r.share, 3), int(r.n)] for h, r in hr_idle.iterrows()],
        "trips": [{"id": r.trip_id, "start": r.start_ts.isoformat(), "end": r.end_ts.isoformat(),
                   "km": r.distance_km, "drive": r.drive_min, "idle": r.idle_min, "avg": r.avg_kmh, "max": r.max_kmh,
                   "events": [int(r.hard_brake), int(r.rapid_accel), int(r.overspeed)],
                   "route": bool(r.has_route), "from": r.from_place, "to": r.to_place} for r in trips.itertuples()],
        "routes": route_json,
        "places": [{"name": r.name, "lat": round(r.lat, 5), "lon": round(r.lon, 5), "visits": int(r.visits)}
                   for r in places.head(12).itertuples()],
        "hotspots": hs,
        "commute": {k: [{"start": r.start_ts.isoformat(), "min": round(r.elapsed_min), "km": r.distance_km}
                        for r in df.itertuples()] for k, df in [("to_work", to_work), ("to_home", to_home)]},
        "service": service_plan(odo, reg, pace, today_date, services),
        "services": services,
        "milestones": milestones,
        "fuel": [[r.taken_at.isoformat(), r.fuel_pct, r.range_km] for r in snap_rows.itertuples()],
    }


def clean(o):
    """JSON-safe copy: NaN/NaT become null, numpy scalars become Python numbers."""
    if isinstance(o, dict):
        return {k: clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [clean(v) for v in o]
    if isinstance(o, np.generic):
        o = o.item()
    if isinstance(o, float) and not np.isfinite(o):
        return None
    if o is pd.NaT or (not isinstance(o, (str, bool, int, float)) and o is not None and pd.isna(o)):
        return None
    return o


def write(name: str, data: dict) -> None:
    out = OUT.parent / name
    out.write_text(json.dumps(clean(data), allow_nan=False, separators=(",", ":")))
    print(f"Wrote {out.relative_to(ROOT)} ({out.stat().st_size / 1e6:.2f} MB)")


def main() -> None:
    import fuel
    import performance

    trips, points, snaps = load()
    odo_rows = snaps.dropna(subset=["odometer_km"])
    odo = float(odo_rows.odometer_km.iloc[-1]) if len(odo_rows) else float(trips.distance_km.sum())
    fuel_data = fuel.build(trips, odo, snaps)
    delta = fuel_data["calibration"]["delta"] if fuel_data else 0.0
    data = build(trips, points, snaps, delta)
    if fuel_data:
        data["tank"] = fuel_data["tank"]
        data["fuel_rs_per_km"] = fuel_data["totals"]["rs_per_km_model"]
    OUT.parent.mkdir(exist_ok=True)
    write("data.json", data)
    write("performance.json", performance.build(trips, points, odo, delta, fuel_data["model"] if fuel_data else None))
    if fuel_data:
        write("fuel.json", fuel_data)
    for k, v in data["findings"].items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
