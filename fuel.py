"""Fuel analytics: odometer calibration, fill-to-fill economy, Bayesian consumption model, costs.

Inputs: the fuel log CSV (Date, Amount, Location, Quantity, @KM, Rate, Company) and the trip archive.
Used by insights.py, which writes the result to web/fuel.json.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).parent
TANK_L = 37.0
ARAI_KMPL = 20.35          # i20 1.2 petrol type-approval figure; real driving shouldn't beat it
BRIM_L = 30.0              # a fill this large is treated as filling the tank to the brim
PREMIUM_MARKUP = 1.08      # rate this far above your median price = premium petrol
HWY_KMH = 50.0             # trips averaging at least this (while moving) count as highway
# Weak priors from engine physics for a 1.2 L naturally aspirated petrol engine:
# (mean, sd) for city L/100 km, highway L/100 km, idle L/h.
PRIOR = {"city_l100": (7.5, 2.5), "hwy_l100": (5.5, 1.5), "idle_lph": (0.75, 0.25)}


def find_csv() -> Path | None:
    for p in [ROOT / "data" / "fuel_log.csv", *sorted(ROOT.glob("*[Ff]uel*.csv"))]:
        if p.exists():
            return p
    return None


def _num(s: pd.Series) -> pd.Series:
    return pd.to_numeric(s.astype(str).str.replace(r"[₹,\s]", "", regex=True), errors="coerce")


def load_fills(path: Path) -> pd.DataFrame:
    raw = pd.read_csv(path).dropna(how="all")
    raw.columns = [c.strip() for c in raw.columns]
    f = pd.DataFrame({
        "date": pd.to_datetime(raw["Date"].str.strip(), format="%a, %d %b %Y"),
        "amount": _num(raw["Amount"]),
        "litres": _num(raw["Quantity"]),
        "logged_km": _num(raw["@KM"]),
        "rate": _num(raw["Rate"]),
        "station": raw["Location"].astype(str).str.strip().str.replace(r"\s+", " ", regex=True),
        "brand": raw["Company"].fillna("").astype(str).str.strip().replace("", "Unknown"),
    }).reset_index(drop=True)
    # Fill gaps in rate/litres from the other two columns where possible.
    f["imputed"] = ""
    need_rate = f.rate.isna() & f.litres.notna() & f.amount.notna()
    f.loc[need_rate, "rate"] = f.amount / f.litres
    f.loc[need_rate, "imputed"] = "rate"
    need_l = f.litres.isna() & f.amount.notna()
    if need_l.any():
        # Rate unknown too: borrow the same station's rate, else the nearest fill's.
        for i in f.index[need_l]:
            same = f[(f.station == f.station[i]) & f.rate.notna()]
            pool = same if len(same) else f[f.rate.notna()]
            near = pool.iloc[(pool.date - f.date[i]).abs().argsort()[:1]]
            f.loc[i, "rate"] = near.rate.iat[0]
            f.loc[i, "litres"] = f.amount[i] / f.rate[i]
            f.loc[i, "imputed"] = "litres"
    f = f.sort_values("date", kind="stable").reset_index(drop=True)
    # Premium petrol: well above your typical price. A global median, not a local one, because state
    # taxes move regular petrol by ~₹10/L (Rajasthan fills look "premium" next to Haryana ones).
    f["premium"] = f.rate > f.rate.median() * PREMIUM_MARKUP
    return f


# ---------- odometer calibration ----------

def _fill_candidates(trips: pd.DataFrame, day: pd.Timestamp) -> list[pd.Timestamp]:
    """Moments a fill could have happened on `day`: before each trip that day, or after the last."""
    d = trips[trips.start_ts.dt.normalize() == day]
    if d.empty:
        return [day + pd.Timedelta(hours=12)]
    return list(d.start_ts) + [d.end_ts.iloc[-1] + pd.Timedelta(minutes=1)]


def _odo_at(trips: pd.DataFrame, moment: pd.Timestamp, odo_now: float, delta: float) -> tuple[float, int, float]:
    after = trips[trips.start_ts >= moment]
    return odo_now - after.distance_km.sum() - delta * len(after), len(after), after.distance_km.sum()


def calibrate(trips: pd.DataFrame, fills: pd.DataFrame, odo_now: float) -> dict:
    """Bluelink rounds each trip's distance down to whole km. Estimate the per-trip loss `delta`
    by matching the odometer rebuilt from trips against the odometer readings in the fuel log.
    The fill's time of day is unknown, so each fill snaps to the trip boundary that day which
    fits best; alternate snapping and least-squares until delta settles."""
    logged = fills.dropna(subset=["logged_km"])
    logged = logged[logged.date >= trips.start_ts.min().normalize()]
    delta = 0.0
    for _ in range(20):
        rows = []
        for r in logged.itertuples():
            best = min(_fill_candidates(trips, r.date),
                       key=lambda m: abs(_odo_at(trips, m, odo_now, delta)[0] - r.logged_km))
            _, n_after, s_after = _odo_at(trips, best, odo_now, delta)
            rows.append((r.Index, n_after, s_after, odo_now - s_after - r.logged_km))
        n = np.array([r[1] for r in rows], float)
        gap = np.array([r[3] for r in rows], float)
        new = float(n @ gap / (n @ n))
        if abs(new - delta) < 1e-6:
            break
        delta = new
    resid = gap - delta * n
    sd = float(resid.std(ddof=1))
    points = [{"date": fills.date[idx].date().isoformat(), "logged_km": float(fills.logged_km[idx]),
               "rebuilt_raw": float(odo_now - s_after),                      # trips summed as Bluelink reports them
               "rebuilt": float(odo_now - s_after - delta * n_after),       # with the per-trip correction
               "resid": float(res), "trips_after": int(n_after)}
              for (idx, n_after, s_after, _), res in zip(rows, resid)]
    return {"delta": delta, "n": len(rows), "resid_sd": sd, "points": points}


# ---------- fill timeline ----------

def place_fills(trips: pd.DataFrame, fills: pd.DataFrame, odo_now: float, delta: float) -> pd.DataFrame:
    """Calibrated odometer and moment for every fill. Logged fills snap to the best-fitting trip
    boundary; unlogged ones take the middle boundary of their day."""
    f = fills.copy()
    first_trip = trips.start_ts.min().normalize()
    moments, odos = [], []
    for r in f.itertuples():
        if r.date < first_trip:
            moments.append(pd.NaT)
            odos.append(np.nan)  # before the trip archive starts: odometer unknown
            continue
        cands = _fill_candidates(trips, r.date)
        if pd.notna(r.logged_km):
            m = min(cands, key=lambda c: abs(_odo_at(trips, c, odo_now, delta)[0] - r.logged_km))
        else:
            m = cands[len(cands) // 2]
        moments.append(m)
        odos.append(_odo_at(trips, m, odo_now, delta)[0])
    f["moment"] = moments
    f["odo"] = odos
    f["brim"] = f.litres >= BRIM_L
    f["over_tank"] = f.litres > TANK_L
    return f


def intervals(trips: pd.DataFrame, f: pd.DataFrame, delta: float) -> pd.DataFrame:
    """Brim-to-brim intervals: litres burned = everything bought after one brim fill up to and
    including the next. Intervals beating the type-approval figure must hide an unlogged fill."""
    brims = f.index[f.brim & f.odo.notna()].tolist()
    rows = []
    for a, b in zip(brims, brims[1:]):
        seg = trips[(trips.start_ts >= f.moment[a]) & (trips.start_ts < f.moment[b])]
        km = float(f.odo[b] - f.odo[a])
        litres = float(f.litres[a + 1:b + 1].sum())
        adj = seg.distance_km + delta
        hwy = seg.avg_kmh >= HWY_KMH
        rows.append({
            "from": f.date[a].date().isoformat(), "to": f.date[b].date().isoformat(),
            "km": km, "litres": litres, "kmpl": km / litres if litres else None,
            "city_km": float(adj[~hwy].sum()), "hwy_km": float(adj[hwy].sum()),
            "idle_h": float(seg.idle_min.sum() / 60), "trips": int(len(seg)),
            "fills": int(b - a), "avg_moving_kmh": float(adj.sum() / (seg.drive_min.sum() / 60)) if seg.drive_min.sum() else None,
        })
    iv = pd.DataFrame(rows)
    if len(iv):
        # The trip-based split doesn't add up to the odometer exactly; rescale it to the odometer distance.
        scale = iv.km / (iv.city_km + iv.hwy_km).where(lambda s: s > 0)
        iv["city_km"] *= scale
        iv["hwy_km"] *= scale
        iv["hwy_share"] = iv.hwy_km / iv.km
        iv["status"] = np.where(iv.kmpl > ARAI_KMPL, "missing_fill", "ok")
    return iv


# ---------- Bayesian consumption model ----------

def fit_model(iv: pd.DataFrame) -> dict:
    """litres = city_km/100 * a + hwy_km/100 * b + idle_h * c, Gaussian priors on (a, b, c),
    Gaussian noise. Noise scale chosen by maximum marginal likelihood (empirical Bayes)."""
    ok = iv[iv.status == "ok"]
    X = np.c_[ok.city_km / 100, ok.hwy_km / 100, ok.idle_h]
    y = ok.litres.to_numpy()
    m0 = np.array([PRIOR[k][0] for k in PRIOR])
    s0 = np.array([PRIOR[k][1] for k in PRIOR])
    P0 = np.diag(1 / s0 ** 2)

    def posterior(sigma, Xs=X, ys=y):
        Pn = P0 + Xs.T @ Xs / sigma ** 2
        Sn = np.linalg.inv(Pn)
        mn = Sn @ (P0 @ m0 + Xs.T @ ys / sigma ** 2)
        return mn, Sn

    def log_evidence(sigma):
        C = X @ np.diag(s0 ** 2) @ X.T + sigma ** 2 * np.eye(len(y))
        r = y - X @ m0
        _, logdet = np.linalg.slogdet(C)
        return -0.5 * (r @ np.linalg.solve(C, r) + logdet + len(y) * np.log(2 * np.pi))

    grid = np.linspace(1.0, 12.0, 111)
    ev = np.array([log_evidence(s) for s in grid])
    sigma = float(grid[ev.argmax()])
    mn, Sn = posterior(sigma)
    sd = np.sqrt(np.diag(Sn))
    pred = X @ mn
    loo, naive = [], []
    overall = ok.km.sum() / ok.litres.sum()
    for i in range(len(y)):
        k = np.arange(len(y)) != i
        mk, _ = posterior(sigma, X[k], y[k])
        loo.append(y[i] - X[i] @ mk)
        kmpl_k = ok.km.to_numpy()[k].sum() / y[k].sum()
        naive.append(y[i] - ok.km.iat[i] / kmpl_k)
    names = list(PRIOR)
    curves = {}
    for j, n in enumerate(names):
        lo = min(m0[j] - 3.5 * s0[j], mn[j] - 4 * sd[j])
        hi = max(m0[j] + 3.5 * s0[j], mn[j] + 4 * sd[j])
        xs = np.linspace(max(lo, 0), hi, 120)
        pdf = lambda x, m, s: np.exp(-0.5 * ((x - m) / s) ** 2) / (s * np.sqrt(2 * np.pi))
        curves[n] = {"x": xs.round(4).tolist(), "prior": pdf(xs, m0[j], s0[j]).round(5).tolist(),
                     "posterior": pdf(xs, mn[j], sd[j]).round(5).tolist()}
    corr = Sn / np.outer(sd, sd)
    return {
        "coef": dict(zip(names, mn.round(4).tolist())),
        "sd": dict(zip(names, sd.round(4).tolist())),
        "prior": {k: {"mean": v[0], "sd": v[1]} for k, v in PRIOR.items()},
        "posterior_corr": corr.round(3).tolist(),
        "sigma_l": sigma,
        "evidence": {"sigma": grid.round(2).tolist(), "log_evidence": ev.round(3).tolist()},
        "n_intervals": int(len(y)),
        "r2": float(1 - ((y - pred) ** 2).sum() / ((y - y.mean()) ** 2).sum()),
        "loo_mae": float(np.mean(np.abs(loo))),
        "naive_loo_mae": float(np.mean(np.abs(naive))),
        "kmpl_city": float(100 / mn[0]),
        "kmpl_hwy": float(100 / mn[1]),
        "curves": curves,
        "fitted": [{"from": r["from"], "to": r["to"], "actual": float(a), "pred": float(p)}
                   for r, a, p in zip(ok.to_dict("records"), y, pred)],
    }


# ---------- per-trip fuel and cost ----------

def trip_costs(trips: pd.DataFrame, f: pd.DataFrame, model: dict, delta: float) -> pd.DataFrame:
    c = model["coef"]
    t = trips.copy()
    t["km_adj"] = t.distance_km + delta
    hwy = t.avg_kmh >= HWY_KMH
    t["move_l"] = np.where(hwy, c["hwy_l100"], c["city_l100"]) * t.km_adj / 100
    t["idle_l"] = c["idle_lph"] * t.idle_min / 60
    t["est_l"] = t.move_l + t.idle_l
    # Price = rate of the most recent fill on or before the trip.
    rates = f[["date", "rate"]].dropna().sort_values("date")
    t = pd.merge_asof(t.sort_values("start_ts"), rates.rename(columns={"date": "start_ts"}), on="start_ts", direction="backward")
    t["rate"] = t.rate.fillna(rates.rate.iat[0])
    t["est_cost"] = t.est_l * t.rate
    t["idle_cost"] = t.idle_l * t.rate
    t["kmpl_est"] = t.km_adj / t.est_l.where(t.est_l > 0)
    return t



# ---------- modelled tank level ----------

def tank_level(t: pd.DataFrame, f: pd.DataFrame, iv: pd.DataFrame, model: dict, snaps: pd.DataFrame) -> dict:
    """Tank contents after every trip: a brim fill resets the tank to full, other fills add their
    litres, and each trip burns the model's estimate. The band is the posterior parameter
    uncertainty of the litres burned since the last brim fill (x' Σ x with x = [city km/100,
    hwy km/100, idle h]). Intervals hiding an unlogged fill are left blank."""
    names = list(PRIOR)
    sd = np.array([model["sd"][k] for k in names])
    cov = np.array(model["posterior_corr"]) * np.outer(sd, sd)
    blank = [(f.moment[f.date == pd.Timestamp(r["from"])].min(), f.moment[f.date == pd.Timestamp(r["to"])].max())
             for r in iv[iv.status == "missing_fill"].to_dict("records")]
    events = [(r.moment, 0, r) for r in f[f.moment.notna()].itertuples()] + [(r.end_ts, 1, r) for r in t.itertuples()]
    level, x, pts = None, np.zeros(3), []

    def emit(ts):
        gap = level is None or any(a <= ts < b for a, b in blank)
        pts.append([ts.isoformat(), None if gap else round(level, 2), None if gap else round(float(np.sqrt(x @ cov @ x)), 2)])

    for ts, kind, r in sorted(events, key=lambda e: (e[0], e[1])):
        if kind == 0:
            if level is not None:
                emit(ts)
            if r.brim:
                level, x = TANK_L, np.zeros(3)
            elif level is not None:
                level = min(level + r.litres, TANK_L)
            if level is not None:
                emit(ts)
        elif level is not None:
            hwy = r.avg_kmh >= HWY_KMH
            x = x + [0 if hwy else r.km_adj / 100, r.km_adj / 100 if hwy else 0, r.idle_min / 60]
            level = max(level - r.est_l, 0.0)
            emit(ts)

    # Gauge readings against the model at the moment the car reported them.
    model_at = pd.Series([p[1] for p in pts], index=pd.to_datetime([p[0] for p in pts]))
    model_at = model_at[~model_at.index.duplicated(keep="last")]
    gauge = []
    for r in snaps.dropna(subset=["fuel_pct"]).itertuples():
        when = r.status_time if pd.notna(r.status_time) else r.taken_at
        before = model_at[:when]
        gauge.append([when.isoformat(), r.fuel_pct, r.range_km,
                      None if before.empty or pd.isna(before.iat[-1]) else round(float(before.iat[-1]) / TANK_L * 100, 1)])
    gauge = [g for i, g in enumerate(gauge) if i == 0 or g[0] != gauge[i - 1][0]]  # one per car report
    return {"points": pts, "gauge": gauge,
            "fills": [[r.moment.isoformat(), round(float(r.litres), 2), bool(r.brim)] for r in f[f.moment.notna()].itertuples()],
            "gaps": [[a.isoformat(), b.isoformat()] for a, b in blank]}


def build(trips: pd.DataFrame, odo_now: float, snaps: pd.DataFrame) -> dict | None:
    path = find_csv()
    if path is None:
        return None
    fills = load_fills(path)
    cal = calibrate(trips, fills, odo_now)
    delta = cal["delta"]
    f = place_fills(trips, fills, odo_now, delta)
    iv = intervals(trips, f, delta)
    model = fit_model(iv)
    t = trip_costs(trips, f, model, delta)

    # Unlogged fuel hiding in the broken intervals, sized by the model.
    c = model["coef"]
    missing = []
    for r in iv[iv.status == "missing_fill"].to_dict("records"):
        need = r["city_km"] / 100 * c["city_l100"] + r["hwy_km"] / 100 * c["hwy_l100"] + r["idle_h"] * c["idle_lph"]
        missing.append({"from": r["from"], "to": r["to"], "km": r["km"], "logged_l": r["litres"],
                        "needed_l": float(need), "unlogged_l": float(need - r["litres"])})

    valid = iv[iv.status == "ok"]
    first_odo = f.odo.dropna().iat[0]
    last = f.iloc[-1]
    month = t.assign(m=t.start_ts.dt.to_period("M").astype(str)).groupby("m").agg(
        km=("km_adj", "sum"), est_l=("est_l", "sum"), est_cost=("est_cost", "sum"), idle_cost=("idle_cost", "sum"))
    spend = f.assign(m=f.date.dt.to_period("M").astype(str)).groupby("m").agg(spend=("amount", "sum"), litres=("litres", "sum"))
    month = month.join(spend, how="outer").fillna(0).reset_index().rename(columns={"index": "m"})

    brands = f.groupby("brand").agg(fills=("rate", "size"), litres=("litres", "sum"), spend=("amount", "sum"),
                                    rate=("rate", "median")).reset_index().sort_values("litres", ascending=False)
    regular = f[~f.premium]
    premium = f[f.premium]
    prem_extra = float(sum(r.litres * (r.rate - regular[(regular.date - r.date).abs() <= pd.Timedelta(days=45)].rate.median())
                           for r in premium.itertuples())) if len(premium) else 0.0

    hwy = t.avg_kmh >= HWY_KMH

    totals = {
        "fills": int(len(f)), "litres": float(f.litres.sum()), "spend": float(f.amount.sum()),
        "avg_rate": float(f.amount.sum() / f.litres.sum()),
        "kmpl_valid": float(valid.km.sum() / valid.litres.sum()) if len(valid) else None,
        "km_valid": float(valid.km.sum()),
        "rs_per_km_model": float(t.est_cost.sum() / t.km_adj.sum()),
        "idle_l": float(t.idle_l.sum()), "idle_cost": float(t.idle_cost.sum()),
        "idle_share_of_fuel": float(t.idle_l.sum() / t.est_l.sum()),
        "est_l_total": float(t.est_l.sum()), "est_cost_total": float(t.est_cost.sum()),
        "city_share_km": float(t.km_adj[~hwy].sum() / t.km_adj.sum()),
        "city_share_fuel": float((t.move_l[~hwy].sum() + t.idle_l[~hwy].sum()) / t.est_l.sum()),
        "premium_fills": int(len(premium)), "premium_extra": prem_extra,
        "missing_fills": len(missing), "unlogged_l": float(sum(m["unlogged_l"] for m in missing)),
        "over_tank": int(f.over_tank.sum()),
        "first_fill": f.date.iat[0].date().isoformat(), "last_fill": last.date.date().isoformat(),
        "odo_span": [float(first_odo), float(f.odo.dropna().iat[-1])],
    }

    return {
        "source": path.name,
        "constants": {"tank_l": TANK_L, "arai_kmpl": ARAI_KMPL, "brim_l": BRIM_L, "hwy_kmh": HWY_KMH,
                      "premium_markup": PREMIUM_MARKUP},
        "calibration": cal,
        "fills": [{
            "date": r.date.date().isoformat(), "moment": r.moment.isoformat() if pd.notna(r.moment) else None,
            "station": r.station, "brand": r.brand, "litres": round(float(r.litres), 2), "amount": round(float(r.amount), 2),
            "rate": round(float(r.rate), 2), "premium": bool(r.premium), "imputed": r.imputed or None,
            "logged_km": None if pd.isna(r.logged_km) else float(r.logged_km),
            "odo": None if pd.isna(r.odo) else round(float(r.odo), 1), "brim": bool(r.brim), "over_tank": bool(r.over_tank),
        } for r in f.itertuples()],
        "intervals": iv.round(3).to_dict("records"),
        "model": model,
        "missing": missing,
        "totals": totals,
        "monthly": [{"month": r.m, "km": round(r.km, 1), "est_l": round(r.est_l, 2), "est_cost": round(r.est_cost),
                     "idle_cost": round(r.idle_cost), "spend": round(r.spend), "litres": round(r.litres, 2)}
                    for r in month.itertuples()],
        "brands": brands.round(2).to_dict("records"),
        "trips": [{"id": r.trip_id, "start": r.start_ts.isoformat(), "km": round(r.km_adj, 2),
                   "est_l": round(r.est_l, 3), "idle_l": round(r.idle_l, 3), "cost": round(r.est_cost, 1),
                   "kmpl": None if pd.isna(r.kmpl_est) else round(r.kmpl_est, 2), "hwy": bool(r.avg_kmh >= HWY_KMH),
                   "avg": r.avg_kmh, "idle_share": round(r.idle_min / (r.drive_min + r.idle_min), 3) if (r.drive_min + r.idle_min) else 0}
                  for r in t.itertuples()],
        "fuel_level": [[r.taken_at.isoformat(), r.fuel_pct, r.range_km] for r in snaps.dropna(subset=["fuel_pct"]).itertuples()],
        "tank": tank_level(t, f, iv, model, snaps),
    }
