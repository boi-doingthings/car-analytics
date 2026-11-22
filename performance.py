"""Performance-engineering analytics over the trip archive. Used by insights.py -> web/performance.json.

Trip features come from Bluelink's per-trip stats (every trip); drive-cycle features come from the
GPS breadcrumbs (~10 s resolution, routed trips only), so accelerations are low-pass estimates.
"""

from __future__ import annotations

import datetime as dt
import os

import numpy as np
import pandas as pd
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler

COLD_SOAK_H = 4.0          # engine considered fully cold after this long parked
STOP_KMH, MOVE_KMH = 3.0, 10.0
BANDS = [(0, 5, "Stopped"), (5, 20, "5–20"), (20, 40, "20–40"), (40, 60, "40–60"),
         (60, 80, "60–80"), (80, 100, "80–100"), (100, 999, "100+")]
# WLTC class 3b phases: average speed incl. stops, max speed (km/h).
WLTC = [("Low", 18.9, 56.5), ("Medium", 39.5, 76.6), ("High", 56.7, 97.4), ("Extra high", 91.7, 131.3)]
K = 3                      # three clusters: the most a scatter can show with colour-blind-safe hues
CLUSTER_FEATURES = ["log_km", "overall_kmh", "idle_share", "max_kmh", "log_min"]


def trip_features(trips: pd.DataFrame, delta: float) -> pd.DataFrame:
    t = trips.sort_values("start_ts").copy()
    t["km"] = t.distance_km + delta
    t["elapsed_min"] = (t.end_ts - t.start_ts).dt.total_seconds() / 60
    t["engine_min"] = t.drive_min + t.idle_min
    t["idle_share"] = (t.idle_min / t.engine_min.where(t.engine_min > 0)).fillna(0)
    t["overall_kmh"] = t.km / (t.elapsed_min.clip(lower=1) / 60)
    t["soak_h"] = (t.start_ts - t.end_ts.shift()).dt.total_seconds() / 3600
    t["cold"] = t.soak_h.isna() | (t.soak_h >= COLD_SOAK_H)
    t["hour"] = t.start_ts.dt.hour + t.start_ts.dt.minute / 60
    t["wd"] = t.start_ts.dt.dayofweek
    t["events"] = t.hard_brake + t.rapid_accel + t.overspeed
    t["log_km"] = np.log1p(t.km)
    t["log_min"] = np.log1p(t.elapsed_min)
    return t


def gps_features(points: pd.DataFrame) -> tuple[pd.DataFrame, dict, dict]:
    """Per-trip drive-cycle metrics plus the pooled speed-acceleration distribution."""
    p = points.sort_values(["trip_id", "t"]).copy()
    p["dt"] = p.groupby("trip_id").t.diff().dt.total_seconds().clip(upper=30).fillna(0)
    v = p.speed / 3.6
    p["acc"] = (v.groupby(p.trip_id).diff() / p.dt.where(p.dt > 0)).clip(-3, 3).fillna(0)
    p["band"] = pd.cut(p.speed, [b[0] for b in BANDS] + [999], right=False, labels=[b[2] for b in BANDS])
    rows = []
    for tid, g in p.groupby("trip_id"):
        secs = g.dt.sum()
        if secs <= 0:
            continue
        dist_m = float((g.speed / 3.6 * g.dt).sum())
        moving = False
        stops = 0
        for s in g.speed:
            if s >= MOVE_KMH:
                moving = True
            elif s < STOP_KMH and moving:
                stops += 1
                moving = False
        rpa = float((g.speed / 3.6 * g.acc.clip(lower=0) * g.dt).sum() / dist_m) if dist_m > 50 else np.nan
        bands = g.groupby("band", observed=False).dt.sum() / secs
        rows.append({"trip_id": tid, "rpa": rpa, "stops": stops,
                     "stops_per_km": stops / (dist_m / 1000) if dist_m > 200 else np.nan,
                     "p95_kmh": float(g.speed.quantile(0.95)), "gps_secs": float(secs),
                     **{f"band_{b}": float(bands.get(b, 0)) for b in [x[2] for x in BANDS]}})
    gf = pd.DataFrame(rows)

    # Pooled speed x acceleration occupancy (seconds), moving samples only.
    m = p[p.speed >= 2]
    vb = np.arange(0, 141, 10)
    ab = np.round(np.arange(-1.5, 1.51, 0.25), 2)
    h, _, _ = np.histogram2d(m.speed.clip(0, 139.9), m.acc.clip(-1.499, 1.499), bins=[vb, ab], weights=m.dt)
    va = {"speed_edges": vb.tolist(), "acc_edges": ab.tolist(), "seconds": h.round(1).tolist()}

    tot = p.groupby("band", observed=False).dt.sum()
    pooled = {"bands": [b[2] for b in BANDS], "share": (tot / tot.sum()).round(4).tolist()}
    return gf, va, pooled


def cluster(t: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    X = StandardScaler().fit_transform(t[CLUSTER_FEATURES])
    sil = {}
    for k in range(2, 7):
        km = KMeans(k, n_init=20, random_state=0).fit(X)
        sil[k] = float(silhouette_score(X, km.labels_, sample_size=None))
    km = KMeans(K, n_init=50, random_state=0).fit(X)
    t = t.assign(cluster=km.labels_)
    pca = PCA(2, random_state=0).fit(X)
    xy = pca.transform(X)
    t["pc1"], t["pc2"] = xy[:, 0], xy[:, 1]

    prof = t.groupby("cluster").agg(n=("km", "size"), km=("km", "median"), overall_kmh=("overall_kmh", "median"),
                                    idle_share=("idle_share", "median"), max_kmh=("max_kmh", "median"),
                                    minutes=("elapsed_min", "median"), km_total=("km", "sum"))

    def name(r):
        if r.overall_kmh >= 40 or r.max_kmh >= 85:
            return "Highway runs"
        if r.km < 4:
            return "Short hops"
        if r.idle_share >= 0.33:
            return "Stop-and-go"
        return "City trips"
    names = {c: name(r) for c, r in prof.iterrows()}
    seen = {}
    for c in sorted(names, key=lambda c: -prof.km.loc[c]):  # disambiguate duplicates
        n = names[c]
        seen[n] = seen.get(n, 0) + 1
        if seen[n] > 1:
            names[c] = f"{n} ({'longer' if seen[n] == 1 else 'shorter'})"
    # Stable display order: highway first, then by median distance.
    order = sorted(prof.index, key=lambda c: (-prof.overall_kmh.loc[c]))
    remap = {old: new for new, old in enumerate(order)}
    t["cluster"] = t.cluster.map(remap)
    prof = prof.rename(index=remap).sort_index()
    names = {remap[c]: n for c, n in names.items()}
    prof["share_km"] = prof.km_total / prof.km_total.sum()
    loadings = pca.components_.T * np.sqrt(pca.explained_variance_)
    return t, {
        "k": K, "silhouette": sil, "features": CLUSTER_FEATURES,
        "explained_variance": pca.explained_variance_ratio_.round(4).tolist(),
        "loadings": {f: loadings[i].round(3).tolist() for i, f in enumerate(CLUSTER_FEATURES)},
        "profiles": [{"cluster": int(c), "name": names[c], **{k: round(float(v), 3) for k, v in r.items()}}
                     for c, r in prof.iterrows()],
    }


def power_law(t: pd.DataFrame) -> dict:
    """log(minutes) = a + b log(km): how trip time scales with distance; outliers by studentized residual."""
    d = t[(t.km >= 1) & (t.elapsed_min >= 2)]
    x, y = np.log(d.km.to_numpy()), np.log(d.elapsed_min.to_numpy())
    X = np.c_[np.ones_like(x), x]
    beta, *_ = np.linalg.lstsq(X, y, rcond=None)
    res = y - X @ beta
    n, k = X.shape
    s = np.sqrt(res @ res / (n - k))
    XtXi = np.linalg.inv(X.T @ X)
    lev = np.einsum("ij,jk,ik->i", X, XtXi, X)
    stud = res / (s * np.sqrt(1 - lev))
    gx = np.linspace(x.min(), x.max(), 60)
    G = np.c_[np.ones_like(gx), gx]
    se_pred = s * np.sqrt(1 + np.einsum("ij,jk,ik->i", G, XtXi, G))
    out = d.assign(stud=stud, expected=np.exp(X @ beta))
    top = out[np.abs(out.stud) > 2.5].sort_values("stud", ascending=False)
    return {
        "a": float(beta[0]), "b": float(beta[1]), "s": float(s), "r2": float(1 - res.var() / y.var()), "n": int(n),
        "band": {"km": np.exp(gx).round(3).tolist(), "fit": np.exp(G @ beta).round(2).tolist(),
                 "lo": np.exp(G @ beta - 1.96 * se_pred).round(2).tolist(), "hi": np.exp(G @ beta + 1.96 * se_pred).round(2).tolist()},
        "outliers": [{"id": r.trip_id, "start": r.start_ts.isoformat(), "km": round(r.km, 1), "minutes": round(r.elapsed_min),
                      "expected": round(r.expected), "stud": round(r.stud, 2), "idle_min": r.idle_min} for r in top.itertuples()],
    }


def commute_reliability(t: pd.DataFrame) -> dict | None:
    out = {}
    for key, a, b in [("to_work", "Home", "Work"), ("to_home", "Work", "Home")]:
        d = t[(t.from_place == a) & (t.to_place == b)]
        if len(d) < 8:
            continue
        m = d.elapsed_min
        p5, p50, p95, mean = m.quantile(0.05), m.median(), m.quantile(0.95), m.mean()
        dep = d.start_ts.dt.hour + d.start_ts.dt.minute / 60
        slot = (np.floor(dep * 4) / 4)
        by = d.assign(slot=slot).groupby("slot").elapsed_min.agg(["median", "size", lambda s: s.quantile(0.25), lambda s: s.quantile(0.75)])
        by.columns = ["median", "n", "q1", "q3"]
        by = by[by.n >= 2]
        wd = d.groupby(d.start_ts.dt.dayofweek).elapsed_min.median()
        out[key] = {
            "n": int(len(d)), "free_flow": float(p5), "median": float(p50), "mean": float(mean), "p95": float(p95),
            "pti": float(p95 / p5), "bti": float((p95 - mean) / mean), "km": float(d.km.median()),
            "minutes": m.round(1).tolist(),
            "by_slot": [[float(i), float(r["median"]), int(r.n), float(r.q1), float(r.q3)] for i, r in by.iterrows()],
            "by_weekday": [[int(i), float(v)] for i, v in wd.items()],
            "trips": [[r.start_ts.isoformat(), round(r.elapsed_min, 1), round(r.idle_min / max(r.engine_min, 1), 3)] for r in d.itertuples()],
        }
    return out or None


def today() -> dt.date:
    """Today, or I20_TODAY (YYYY-MM-DD) when set, so oracle outputs are reproducible."""
    return dt.date.fromisoformat(os.environ["I20_TODAY"]) if os.environ.get("I20_TODAY") else dt.date.today()


def forecast(t: pd.DataFrame, odo_now: float, horizon_days: int = 240, window_days: int = 120) -> dict:
    """Odometer forecast: daily km treated as i.i.d. over the recent window, with the uncertainty
    in the mean included. Bands are normal approximations to the cumulative sum."""
    daily = t.groupby(t.start_ts.dt.normalize()).km.sum()
    idx = pd.date_range(daily.index.min(), pd.Timestamp(today()))
    daily = daily.reindex(idx, fill_value=0.0)
    odo = odo_now - daily[::-1].cumsum()[::-1].shift(-1, fill_value=0)
    recent = daily[-window_days:]
    mu, sd, n = recent.mean(), recent.std(ddof=1), len(recent)
    h = np.arange(1, horizon_days + 1)
    mean = odo_now + mu * h
    spread = np.sqrt(h * sd ** 2 + (h * sd / np.sqrt(n)) ** 2)
    future = pd.date_range(idx[-1] + pd.Timedelta(days=1), periods=horizon_days)

    def cross(level, series):
        hit = np.nonzero(series >= level)[0]
        return future[hit[0]].date().isoformat() if len(hit) else None
    milestones = []
    for level in range(int(odo_now // 5000 + 1) * 5000, int(mean[-1]) + 1, 5000):
        milestones.append({"km": level, "p50": cross(level, mean), "early": cross(level, mean + 1.2816 * spread),
                           "late": cross(level, mean - 1.2816 * spread)})
    weekly = daily.resample("W-SUN").sum()
    return {
        "history": [[d.date().isoformat(), round(float(o), 1)] for d, o in odo.items()],
        "future": [[d.date().isoformat(), round(float(m), 1), round(float(m - 1.2816 * s), 1), round(float(m + 1.2816 * s), 1)]
                   for d, m, s in zip(future, mean, spread)],
        "km_per_day": float(mu), "sd_per_day": float(sd), "window_days": window_days, "milestones": milestones,
        "weekly": [[d.date().isoformat(), round(float(v), 1)] for d, v in weekly.items()],
    }


def cold_starts(t: pd.DataFrame) -> dict:
    edges = [0, 1 / 6, 0.5, 1, 2, 4, 8, 16, 1e9]
    labels = ["<10 min", "10–30 min", "30–60 min", "1–2 h", "2–4 h", "4–8 h", "8–16 h", "16 h+"]
    s = t.soak_h.dropna()
    hist = pd.cut(s, edges, labels=labels, right=False).value_counts().reindex(labels, fill_value=0)
    short_cold = t[t.cold & (t.km < 5)]
    return {"labels": labels, "counts": hist.astype(int).tolist(), "cold_share": float(t.cold.mean()),
            "short_cold": int(len(short_cold)), "short_cold_share": float(len(short_cold) / len(t)),
            "short_cold_km": float(short_cold.km.sum()), "threshold_h": COLD_SOAK_H}


def correlations(t: pd.DataFrame) -> dict:
    cols = {"km": "Distance", "elapsed_min": "Duration", "avg_kmh": "Moving speed", "overall_kmh": "Overall speed",
            "max_kmh": "Top speed", "idle_share": "Idle share", "hour": "Start hour", "soak_h": "Soak time", "events": "Alerts"}
    c = t[list(cols)].corr(method="spearman").round(3)
    return {"labels": list(cols.values()), "matrix": c.values.tolist()}


def build(trips: pd.DataFrame, points: pd.DataFrame, odo_now: float, delta: float, fuel_model: dict | None) -> dict:
    t = trip_features(trips, delta)
    gf, va, pooled = gps_features(points) if len(points) else (pd.DataFrame(), None, None)
    if len(gf):
        t = t.merge(gf, on="trip_id", how="left")
    t, clusters = cluster(t)
    routed = t[t.rpa.notna()] if "rpa" in t else t.iloc[0:0]

    # Time-in-band by cluster (routed trips only, time-weighted).
    band_cols = [f"band_{b[2]}" for b in BANDS]
    by_cluster = []
    if len(routed):
        for c, g in routed.groupby("cluster"):
            w = g.gps_secs
            by_cluster.append({"cluster": int(c), "n": int(len(g)),
                               "share": [(g[col] * w).sum() / w.sum() for col in band_cols]})

    month = t.groupby(t.start_ts.dt.to_period("M").astype(str)).agg(
        km=("km", "sum"), trips=("km", "size"), moving_kmh=("avg_kmh", "median"), overall_kmh=("overall_kmh", "median"),
        idle_share=("idle_share", "median"), engine_h=("engine_min", lambda s: s.sum() / 60), events=("events", "sum"))
    idle_cost = None
    if fuel_model:
        c = fuel_model["coef"]
        idle_cost = {"lph": c["idle_lph"], "litres": float(t.idle_min.sum() / 60 * c["idle_lph"])}

    keep = ["trip_id", "start_ts", "km", "elapsed_min", "avg_kmh", "overall_kmh", "max_kmh", "idle_share", "soak_h",
            "cold", "cluster", "pc1", "pc2", "events", "rpa", "stops_per_km", "p95_kmh", *band_cols]
    keep = [k for k in keep if k in t]
    trips_out = t[keep].copy()
    trips_out["start_ts"] = trips_out.start_ts.dt.strftime("%Y-%m-%dT%H:%M:%S")
    engine_h = float(t.engine_min.sum() / 60)
    return {
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "delta_km_per_trip": delta,
        "totals": {"trips": int(len(t)), "km": float(t.km.sum()), "engine_h": engine_h, "km_per_engine_h": float(t.km.sum() / engine_h),
                   "routed": int(len(routed)), "rpa_median": float(routed.rpa.median()) if len(routed) else None,
                   "stops_per_km_median": float(routed.stops_per_km.median()) if len(routed) else None,
                   "idle_h": float(t.idle_min.sum() / 60)},
        "trips": trips_out.round(4).to_dict("records"),
        "wltc": [{"phase": p, "avg_kmh": a, "max_kmh": m} for p, a, m in WLTC],
        "speed_bands": pooled,
        "bands_by_cluster": by_cluster,
        "speed_accel": va,
        "clusters": clusters,
        "power_law": power_law(t),
        "commute": commute_reliability(t) if "from_place" in t else None,
        "forecast": forecast(t, odo_now),
        "cold": cold_starts(t),
        "correlations": correlations(t),
        "monthly": [{"month": m, **{k: round(float(v), 3) for k, v in r.items()}} for m, r in month.iterrows()],
        "idle_fuel": idle_cost,
    }
