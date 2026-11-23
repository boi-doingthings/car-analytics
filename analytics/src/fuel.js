// Fuel model: odometer calibration, brim-to-brim economy, Bayesian consumption model, trip costs and
// the modelled tank level. Port of fuel.py (the Python output is the oracle); see docs/entry-schemas.md
// for the refuel entries that feed `fills`. Consumption validation extends the frozen Python reference.
import { fmtFixed, groupBy, inv, median } from "./util.js";

export const TANK_L = 37.0;
export const ARAI_KMPL = 20.35;
export const BRIM_L = 30.0;
export const PREMIUM_MARKUP = 1.08;
export const HWY_KMH = 50.0;
export const PRIOR = { city_l100: [7.5, 2.5], hwy_l100: [5.5, 1.5], idle_lph: [0.75, 0.25] };
const NAMES = Object.keys(PRIOR);

const DAY = 86400000, MIN = 60000;
const pad = (n) => String(n).padStart(2, "0");
const ms = (iso) => Date.parse(iso + "Z");
const isoOf = (t) => {
  const d = new Date(t);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
};
const dayOf = (t) => Math.floor(t / DAY) * DAY;
const isNum = (v) => v != null && !Number.isNaN(v);

// Python builtin round(x, d): exact decimal, ties to even.
const rnd = (x, d = 0) => (isNum(x) ? Number(fmtFixed(x, d)) : null);
// numpy round: rint(x * 10^d) / 10^d.
const rint = (v) => { const r = Math.round(v); return Math.abs(v % 1) === 0.5 ? 2 * Math.round(v / 2) : r; };
const npr = (x, d) => (isNum(x) ? rint(x * 10 ** d) / 10 ** d : null);
const sum = (xs) => { let s = 0; for (const v of xs) if (isNum(v)) s += v; return s; };
const linspace = (a, b, n) => Array.from({ length: n }, (_, i) => (i === n - 1 ? b : a + (i * (b - a)) / (n - 1)));

// ---------- trips indexed for "everything after this moment" queries ----------

function indexTrips(trips) {
  const T = trips.map((t) => ({ ...t, s: ms(t.start_ts), e: t.end_ts ? ms(t.end_ts) : ms(t.start_ts) }));
  const n = T.length;
  const sufKm = new Array(n + 1).fill(0);
  for (let i = n - 1; i >= 0; i--) sufKm[i] = sufKm[i + 1] + (T[i].distance_km ?? 0);
  const byDay = new Map();
  T.forEach((t, i) => { const d = dayOf(t.s); if (!byDay.has(d)) byDay.set(d, []); byDay.get(d).push(i); });
  const firstAt = (moment) => { // first trip with start >= moment
    let lo = 0, hi = n;
    while (lo < hi) { const m = (lo + hi) >> 1; if (T[m].s >= moment) hi = m; else lo = m + 1; }
    return lo;
  };
  const candidates = (day) => { // moments a fill could have happened on `day`
    const ix = byDay.get(day);
    if (!ix) return [day + 12 * 60 * MIN];
    return [...ix.map((i) => T[i].s), T[ix[ix.length - 1]].e + MIN];
  };
  const odoAt = (moment, odoNow, delta) => {
    const k = firstAt(moment), cnt = n - k;
    return { odo: odoNow - sufKm[k] - delta * cnt, n: cnt, s: sufKm[k] };
  };
  const best = (day, logged, odoNow, delta) => {
    let bm = null, bd = Infinity;
    for (const c of candidates(day)) {
      const d = Math.abs(odoAt(c, odoNow, delta).odo - logged);
      if (d < bd) { bd = d; bm = c; }
    }
    return bm;
  };
  return { T, firstDay: dayOf(T[0].s), firstAt, candidates, odoAt, best };
}

// A fill logged after the fact has no odometer reading of its own.
const hasOdo = (f) => !f.missed && f.logged_km != null;
const isBrim = (f) => f.full_tank ?? (isNum(f.litres) && f.litres >= BRIM_L);

// ---------- odometer calibration ----------

/** Bluelink floors each trip's distance to whole km; estimate the per-trip loss `delta` by matching
 *  the odometer rebuilt from trips to the logged odometer readings (snap each fill to its best trip
 *  boundary, least squares, repeat until delta settles). */
function calibrate(ix, fills, odoNow) {
  const logged = fills.map((f, i) => [f, i]).filter(([f]) => hasOdo(f) && ms(f.date) >= ix.firstDay);
  let delta = 0, rows = [], gap = [];
  for (let it = 0; it < 20; it++) {
    rows = logged.map(([f, i]) => {
      const m = ix.best(ms(f.date), f.logged_km, odoNow, delta);
      const { n, s } = ix.odoAt(m, odoNow, delta);
      return { i, n, s, gap: odoNow - s - f.logged_km };
    });
    gap = rows.map((r) => r.gap);
    const nn = rows.reduce((a, r) => a + r.n * r.n, 0);
    const next = nn ? rows.reduce((a, r) => a + r.n * r.gap, 0) / nn : 0;
    if (Math.abs(next - delta) < 1e-6) break;
    delta = next;
  }
  const resid = rows.map((r) => r.gap - delta * r.n);
  let sd = null;
  if (resid.length > 1) {
    const mean = sum(resid) / resid.length;
    sd = Math.sqrt(sum(resid.map((v) => (v - mean) ** 2)) / (resid.length - 1));
  }
  const points = rows.map((r, k) => ({
    date: fills[r.i].date.slice(0, 10), logged_km: fills[r.i].logged_km,
    rebuilt_raw: odoNow - r.s, rebuilt: odoNow - r.s - delta * r.n,
    resid: resid[k], trips_after: r.n,
  }));
  return { delta, n: rows.length, resid_sd: sd, points };
}

// ---------- fill timeline ----------

/** Calibrated odometer and moment for every fill. Logged fills snap to the best-fitting trip
 *  boundary; unlogged and missed ones take the middle boundary of their day. */
function placeFills(ix, fills, odoNow, delta) {
  return fills.map((f) => {
    const out = { ...f, brim: isBrim(f), over_tank: isNum(f.litres) && f.litres > TANK_L, moment: null, odo: null };
    const day = ms(f.date);
    if (day < ix.firstDay) return out; // before the trip archive starts: odometer unknown
    const cands = ix.candidates(day);
    out.moment = hasOdo(f) ? ix.best(day, f.logged_km, odoNow, delta) : cands[cands.length >> 1];
    out.odo = ix.odoAt(out.moment, odoNow, delta).odo;
    return out;
  });
}

/** Brim-to-brim intervals. Intervals beating the type-approval figure, or holding a fill of unknown
 *  litres, hide fuel that was never logged: status "missing_fill". */
function intervals(ix, f, delta) {
  const brims = f.map((r, i) => i).filter((i) => f[i].brim && f[i].odo != null);
  const rows = [];
  for (let k = 0; k + 1 < brims.length; k++) {
    const a = brims[k], b = brims[k + 1];
    const seg = ix.T.slice(ix.firstAt(f[a].moment), ix.firstAt(f[b].moment));
    const km = f[b].odo - f[a].odo;
    const held = f.slice(a + 1, b + 1);
    const litres = sum(held.map((r) => r.litres));
    const unknown = held.some((r) => !isNum(r.litres));
    const hwy = seg.map((t) => t.avg_kmh >= HWY_KMH);
    const adj = seg.map((t) => t.distance_km + delta);
    const drive = sum(seg.map((t) => t.drive_min));
    rows.push({
      from: f[a].date.slice(0, 10), to: f[b].date.slice(0, 10), km, litres, kmpl: litres ? km / litres : null,
      city_km: sum(adj.filter((_, j) => !hwy[j])), hwy_km: sum(adj.filter((_, j) => hwy[j])),
      idle_h: sum(seg.map((t) => t.idle_min)) / 60, trips: seg.length, fills: b - a,
      avg_moving_kmh: drive ? sum(adj) / (drive / 60) : null, unknown,
    });
  }
  for (const r of rows) {
    // The trip-based split doesn't add up to the odometer exactly; rescale it to the odometer distance.
    const tot = r.city_km + r.hwy_km;
    const scale = tot > 0 ? r.km / tot : NaN;
    r.city_km *= scale;
    r.hwy_km *= scale;
    r.hwy_share = r.hwy_km / r.km;
    const usable = r.km > 0 && r.trips > 0 && Number.isFinite(r.city_km) && Number.isFinite(r.hwy_km) && r.litres > 0;
    r.status = r.unknown ? "missing_fill" : !usable ? "degenerate" : r.kmpl > ARAI_KMPL ? "missing_fill" : "ok";
  }
  return rows;
}

// ---------- Bayesian consumption model ----------

/** Cholesky factor of a symmetric positive-definite matrix. */
function cholesky(A) {
  const n = A.length;
  const L = Array.from({ length: n }, () => new Array(n).fill(0));
  for (let i = 0; i < n; i++) {
    for (let j = 0; j <= i; j++) {
      let s = A[i][j];
      for (let k = 0; k < j; k++) s -= L[i][k] * L[j][k];
      if (i === j) { if (s <= 0) throw new Error("matrix not positive definite"); L[i][i] = Math.sqrt(s); } else L[i][j] = s / L[j][j];
    }
  }
  return L;
}
function cholSolve(L, b) {
  const n = L.length, z = new Array(n), x = new Array(n);
  for (let i = 0; i < n; i++) { let s = b[i]; for (let k = 0; k < i; k++) s -= L[i][k] * z[k]; z[i] = s / L[i][i]; }
  for (let i = n - 1; i >= 0; i--) { let s = z[i]; for (let k = i + 1; k < n; k++) s -= L[k][i] * x[k]; x[i] = s / L[i][i]; }
  return x;
}

/** litres = city_km/100 * a + hwy_km/100 * b + idle_h * c with Gaussian priors on (a, b, c) and
 *  Gaussian noise; the noise scale maximises the marginal likelihood (empirical Bayes).
 *  Exported to validate the consumption fit independently using invented, constructed intervals.
 *  Validation is conditional on precomputed calibration and interval eligibility, not a full pipeline forecast. */
export function fitModel(iv) {
  const ok = iv.filter((r) => r.status === "ok");
  const X = ok.map((r) => [r.city_km / 100, r.hwy_km / 100, r.idle_h]);
  const y = ok.map((r) => r.litres);
  const N = y.length;
  const m0 = NAMES.map((k) => PRIOR[k][0]), s0 = NAMES.map((k) => PRIOR[k][1]);
  const P0d = s0.map((s) => 1 / s ** 2);

  const posterior = (sigma, Xs, ys) => {
    const Pn = [0, 1, 2].map((i) => [0, 1, 2].map((j) => (i === j ? P0d[i] : 0) + Xs.reduce((a, r) => a + r[i] * r[j], 0) / sigma ** 2));
    const Sn = inv(Pn);
    const rhs = [0, 1, 2].map((i) => P0d[i] * m0[i] + Xs.reduce((a, r, k) => a + r[i] * ys[k], 0) / sigma ** 2);
    return { mn: cholSolve(cholesky(Pn), rhs), Sn, precision: Pn };
  };
  // Matrix determinant lemma keeps noise tuning at a 3 × 3 factorization rather than an
  // interval-count-sized covariance. This matters when each validation fold retunes sigma.
  const logEvidence = (sigma, Xs, ys) => {
    if (!ys.length) return 0;
    const { mn, precision } = posterior(sigma, Xs, ys);
    const L = cholesky(precision);
    const logdet = 2 * ys.length * Math.log(sigma) + s0.reduce((a, sd) => a + 2 * Math.log(sd), 0)
      + 2 * L.reduce((a, row, i) => a + Math.log(row[i]), 0);
    // At the posterior mean this positive-sum form equals r' C^-1 r, avoiding cancellation.
    const residual = ys.reduce((a, value, i) => a + (value - Xs[i].reduce((v, x, j) => v + x * mn[j], 0)) ** 2, 0) / sigma ** 2;
    const priorPenalty = mn.reduce((a, value, j) => a + (value - m0[j]) ** 2 / s0[j] ** 2, 0);
    return -0.5 * (residual + priorPenalty + logdet + ys.length * Math.log(2 * Math.PI));
  };

  const grid = linspace(1.0, 12.0, 111);
  const selectNoise = (Xs, ys) => {
    const evidence = grid.map((sigma) => logEvidence(sigma, Xs, ys));
    let best = 0;
    evidence.forEach((value, i) => { if (value > evidence[best]) best = i; });
    return { sigma: grid[best], evidence };
  };
  const { sigma, evidence: ev } = selectNoise(X, y);
  const { mn, Sn } = posterior(sigma, X, y);
  const sd = [0, 1, 2].map((i) => Math.sqrt(Sn[i][i]));
  const pred = X.map((xi) => xi.reduce((a, v, k) => a + v * mn[k], 0));

  const minChronologicalTrain = 3;
  const predict = (test, training) => {
    const Xs = training.map((i) => X[i]), ys = training.map((i) => y[i]);
    // The held-out litres are deliberately unavailable to BOTH coefficient and noise selection.
    const { sigma: foldSigma } = selectNoise(Xs, ys);
    const { mn: coefficients } = posterior(foldSigma, Xs, ys);
    const predicted = X[test].reduce((value, x, j) => value + x * coefficients[j], 0);
    const trainKM = training.reduce((total, i) => total + ok[i].km, 0);
    const trainLitres = ys.reduce((total, value) => total + value, 0);
    // The baseline is a pooled fuel rate (L/km), trained on exactly the same intervals.
    const baseline = trainKM > 0 ? ok[test].km * trainLitres / trainKM : null;
    return {
      from: ok[test].from, to: ok[test].to, train_intervals: training.length,
      sigma_l: foldSigma, actual_l: y[test], predicted_l: predicted, baseline_l: baseline,
      error_l: predicted - y[test], baseline_error_l: baseline == null ? null : baseline - y[test],
    };
  };
  const summarize = (method, minimum, predictions) => {
    const baseline = predictions.filter((row) => row.baseline_error_l != null);
    const mean = (rows, key, absolute = false) => rows.length
      ? rows.reduce((total, row) => total + (absolute ? Math.abs(row[key]) : row[key]), 0) / rows.length : null;
    return {
      method, min_train_intervals: minimum, n_predictions: predictions.length,
      baseline_n_predictions: baseline.length,
      model_mae_l: mean(predictions, "error_l", true), baseline_mae_l: mean(baseline, "baseline_error_l", true),
      model_bias_l: mean(predictions, "error_l"), baseline_bias_l: mean(baseline, "baseline_error_l"),
      predictions,
    };
  };
  const indices = ok.map((_, i) => i);
  const looRows = N >= 2 ? indices.map((test) => predict(test, indices.filter((i) => i !== test))) : [];
  const loo = summarize("nested_leave_one_interval_out", 1, looRows);

  // Outputs currently retain calendar dates rather than fill timestamps. Zero-day intervals
  // cannot be causally ordered from those dates and are excluded from chronological validation.
  const validDay = (day) => typeof day === "string" && /^\d{4}-\d{2}-\d{2}$/.test(day)
    && Number.isFinite(Date.parse(day + "T00:00:00Z"))
    && new Date(day + "T00:00:00Z").toISOString().slice(0, 10) === day;
  const timed = indices.filter((i) => validDay(ok[i].from) && validDay(ok[i].to) && ok[i].from < ok[i].to)
    .sort((a, b) => ok[a].to.localeCompare(ok[b].to) || ok[a].from.localeCompare(ok[b].from) || a - b);
  const chronologicalRows = [];
  for (const test of timed) {
    // A training response must have been observed by the start of this held-out interval.
    // This also excludes intervals that overlap the test, regardless of input ordering.
    const training = timed.filter((i) => i !== test && ok[i].to <= ok[test].from);
    if (training.length >= minChronologicalTrain) chronologicalRows.push(predict(test, training));
  }
  const chronological = {
    ...summarize("expanding_window_one_step", minChronologicalTrain, chronologicalRows),
    eligible_intervals: timed.length,
    excluded_date_intervals: N - timed.length,
    insufficient_history_intervals: timed.length - chronologicalRows.length,
  };
  const validation = {
    schema: 1, units: "litres", bias_definition: "prediction_minus_actual",
    scope: "conditional_on_precomputed_intervals",
    caveat: "Distance calibration, interval eligibility and city/highway splits are precomputed. This evaluates consumption fitting conditional on those inputs, not end-to-end forecasting or causal savings.",
    loo, chronological,
  };

  const pdf = (x, m, s) => Math.exp(-0.5 * ((x - m) / s) ** 2) / (s * Math.sqrt(2 * Math.PI));
  const curves = {};
  NAMES.forEach((n, j) => {
    const lo = Math.min(m0[j] - 3.5 * s0[j], mn[j] - 4 * sd[j]);
    const hi = Math.max(m0[j] + 3.5 * s0[j], mn[j] + 4 * sd[j]);
    const xs = linspace(Math.max(lo, 0), hi, 120);
    curves[n] = { x: xs.map((v) => npr(v, 4)), prior: xs.map((v) => npr(pdf(v, m0[j], s0[j]), 5)),
      posterior: xs.map((v) => npr(pdf(v, mn[j], sd[j]), 5)) };
  });
  const ybar = sum(y) / N;
  const obj = (arr) => Object.fromEntries(NAMES.map((n, j) => [n, arr[j]]));
  return {
    coef: obj(mn.map((v) => npr(v, 4))),
    sd: obj(sd.map((v) => npr(v, 4))),
    prior: Object.fromEntries(NAMES.map((k) => [k, { mean: PRIOR[k][0], sd: PRIOR[k][1] }])),
    posterior_corr: Sn.map((row, i) => row.map((v, j) => npr(v / (sd[i] * sd[j]), 3))),
    sigma_l: sigma,
    evidence: { sigma: grid.map((v) => npr(v, 2)), log_evidence: ev.map((v) => npr(v, 3)) },
    n_intervals: N,
    r2: N < 2 ? null : 1 - sum(y.map((v, i) => (v - pred[i]) ** 2)) / sum(y.map((v) => (v - ybar) ** 2)),
    // Legacy names are retained, now with noise selection nested correctly inside every fold.
    loo_mae: loo.model_mae_l,
    naive_loo_mae: loo.baseline_mae_l,
    validation,
    kmpl_city: 100 / mn[0],
    kmpl_hwy: 100 / mn[1],
    curves,
    fitted: ok.map((r, i) => ({ from: r.from, to: r.to, actual: y[i], pred: pred[i] })),
  };
}

// ---------- per-trip fuel and cost ----------

function tripCosts(ix, f, model, delta) {
  const c = model.coef;
  // Price = rate of the most recent fill on or before the trip (last of equal dates wins).
  const rates = f.filter((r) => isNum(r.rate)).map((r) => [ms(r.date), r.rate]).sort((a, b) => a[0] - b[0]);
  return ix.T.map((t) => {
    const km_adj = t.distance_km + delta;
    const hwy = t.avg_kmh >= HWY_KMH;
    const move_l = (hwy ? c.hwy_l100 : c.city_l100) * km_adj / 100;
    const idle_l = c.idle_lph * t.idle_min / 60;
    const est_l = move_l + idle_l;
    let rate = rates.length ? rates[0][1] : null;
    for (const [d, r] of rates) { if (d <= t.s) rate = r; else break; }
    return { ...t, km_adj, hwy, move_l, idle_l, est_l, rate,
      est_cost: rate == null ? NaN : est_l * rate, idle_cost: rate == null ? NaN : idle_l * rate,
      kmpl_est: est_l > 0 ? km_adj / est_l : null };
  });
}

// ---------- modelled tank level ----------

/** Tank contents after every trip: a brim fill resets to full, other fills add litres, each trip burns
 *  the model's estimate. The band is the posterior uncertainty of litres burned since the last brim
 *  fill. Intervals hiding an unlogged fill are left blank. */
function tankLevel(t, f, iv, model, snaps) {
  const sd = NAMES.map((k) => model.sd[k]);
  const cov = model.posterior_corr.map((row, i) => row.map((v, j) => v * sd[i] * sd[j]));
  const placed = f.filter((r) => r.moment != null);
  const momentsOn = (date) => placed.filter((r) => r.date.slice(0, 10) === date).map((r) => r.moment);
  const blank = iv.filter((r) => r.status === "missing_fill")
    .map((r) => [Math.min(...momentsOn(r.from)), Math.max(...momentsOn(r.to))]);
  const events = [
    ...placed.map((r) => ({ ts: r.moment, kind: 0, r })),
    ...t.map((r) => ({ ts: r.e, kind: 1, r })),
  ].sort((a, b) => a.ts - b.ts || a.kind - b.kind);
  // A fill of unknown litres (not a brim) leaves the tank unknown until the next brim fill, or the end.
  const brimTimes = placed.filter((r) => r.brim).map((r) => r.moment);
  const endTs = events.length ? events[events.length - 1].ts + 1000 : 0;
  for (const r of placed) {
    if (r.brim || isNum(r.litres)) continue;
    blank.push([r.moment, Math.min(endTs, ...brimTimes.filter((b) => b > r.moment))]);
  }

  let level = null, x = [0, 0, 0];
  const pts = [];
  const emit = (ts) => {
    const gap = level === null || blank.some(([a, b]) => a <= ts && ts < b);
    const band = Math.sqrt(x.reduce((s, xi, i) => s + xi * cov[i].reduce((a, v, j) => a + v * x[j], 0), 0));
    pts.push([ts, isoOf(ts), gap ? null : rnd(level, 2), gap ? null : rnd(band, 2)]);
  };
  for (const { ts, kind, r } of events) {
    if (kind === 0) {
      if (level !== null) emit(ts);
      if (r.brim) { level = TANK_L; x = [0, 0, 0]; } else if (level !== null && isNum(r.litres)) level = Math.min(level + r.litres, TANK_L);
      if (level !== null) emit(ts);
    } else if (level !== null) {
      x = [x[0] + (r.hwy ? 0 : r.km_adj / 100), x[1] + (r.hwy ? r.km_adj / 100 : 0), x[2] + r.idle_min / 60];
      level = Math.max(level - r.est_l, 0.0);
      emit(ts);
    }
  }

  // Gauge readings against the model at the moment the car reported them.
  const gauge = [];
  for (const s of snaps.filter((r) => isNum(r.fuel_pct))) {
    const when = s.status_time ?? s.taken_at;
    const w = ms(when);
    let before = null;
    for (const p of pts) { if (p[0] <= w) before = p; else break; }
    gauge.push([when, s.fuel_pct, s.range_km, before === null || before[2] === null ? null : rnd(before[2] / TANK_L * 100, 1)]);
  }
  return {
    points: pts.map((p) => p.slice(1)),
    gauge: gauge.filter((g, i) => i === 0 || g[0] !== gauge[i - 1][0]), // one per car report
    fills: placed.map((r) => [isoOf(r.moment), rnd(r.litres, 2), r.brim]),
    gaps: blank.map(([a, b]) => [isoOf(a), isoOf(b)]),
  };
}

// ---------- build ----------

const median45 = (regular, d0) => median(regular.filter((r) => Math.abs(ms(r.date) - d0) <= 45 * DAY).map((r) => r.rate));

function nanToNull(v) {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (Array.isArray(v)) return v.map(nanToNull);
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, nanToNull(x)]));
  return v;
}

/** tables = loadTables(...); fills = fillsFromRefuels(...); odoNow = last non-null snapshot odometer
 *  (falls back to the summed trip distance). Returns the web/fuel.json shape, or null when there is
 *  nothing to model (no fills, no trips, or no usable brim-to-brim interval). */
export function buildFuel(tables, fills, odoNow, { source = "refuel log" } = {}) {
  const { trips, snaps } = tables;
  if (!fills.length || !trips.length) return null;
  const ix = indexTrips(trips);
  odoNow = odoNow ?? sum(trips.map((t) => t.distance_km));

  const cal = calibrate(ix, fills, odoNow);
  const delta = cal.delta;
  const f = placeFills(ix, fills, odoNow, delta);
  const iv = intervals(ix, f, delta);
  if (!iv.some((r) => r.status === "ok")) return null;
  const model = fitModel(iv);
  const t = tripCosts(ix, f, model, delta);

  // Unlogged fuel hiding in the broken intervals, sized by the model.
  const c = model.coef;
  const missing = iv.filter((r) => r.status === "missing_fill").map((r) => {
    const need = r.city_km / 100 * c.city_l100 + r.hwy_km / 100 * c.hwy_l100 + r.idle_h * c.idle_lph;
    return { from: r.from, to: r.to, km: r.km, logged_l: r.litres, needed_l: need, unlogged_l: need - r.litres };
  });

  const valid = iv.filter((r) => r.status === "ok");
  const odos = f.map((r) => r.odo).filter(isNum);
  const premium = f.filter((r) => r.premium), regular = f.filter((r) => !r.premium);
  const premExtra = premium.length
    ? sum(premium.map((r) => (r.litres ?? 0) * (r.rate - median45(regular, ms(r.date))))) : 0.0;
  const cityT = t.filter((r) => !r.hwy);
  const kmAll = sum(t.map((r) => r.km_adj)), estL = sum(t.map((r) => r.est_l)), idleL = sum(t.map((r) => r.idle_l));

  const totals = {
    fills: f.length, litres: sum(f.map((r) => r.litres)), spend: sum(f.map((r) => r.amount)),
    avg_rate: sum(f.map((r) => r.amount)) / sum(f.map((r) => r.litres)),
    kmpl_valid: sum(valid.map((r) => r.km)) / sum(valid.map((r) => r.litres)),
    km_valid: sum(valid.map((r) => r.km)),
    rs_per_km_model: sum(t.map((r) => r.est_cost)) / kmAll,
    idle_l: idleL, idle_cost: sum(t.map((r) => r.idle_cost)), idle_share_of_fuel: idleL / estL,
    est_l_total: estL, est_cost_total: sum(t.map((r) => r.est_cost)),
    city_share_km: sum(cityT.map((r) => r.km_adj)) / kmAll,
    city_share_fuel: (sum(cityT.map((r) => r.move_l)) + sum(cityT.map((r) => r.idle_l))) / estL,
    premium_fills: premium.length, premium_extra: premExtra,
    missing_fills: missing.length, unlogged_l: sum(missing.map((m) => m.unlogged_l)),
    over_tank: f.filter((r) => r.over_tank).length,
    first_fill: f[0].date.slice(0, 10), last_fill: f.at(-1).date.slice(0, 10),
    odo_span: [odos[0], odos.at(-1)],
  };

  const months = new Map(); // month -> {km, est_l, est_cost, idle_cost, spend, litres}
  const slot = (m) => { if (!months.has(m)) months.set(m, { km: 0, est_l: 0, est_cost: 0, idle_cost: 0, spend: 0, litres: 0 }); return months.get(m); };
  for (const r of t) {
    const s = slot(r.start_ts.slice(0, 7));
    s.km += r.km_adj; s.est_l += r.est_l; s.est_cost += r.est_cost; s.idle_cost += r.idle_cost;
  }
  for (const r of f) { const s = slot(r.date.slice(0, 7)); s.spend += r.amount ?? 0; s.litres += r.litres ?? 0; }

  const brands = [...groupBy(f, (r) => r.brand)].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([brand, rs]) => ({ brand, fills: rs.length, litres: sum(rs.map((r) => r.litres)), spend: sum(rs.map((r) => r.amount)),
      rate: median(rs.map((r) => r.rate)) }))
    .sort((a, b) => b.litres - a.litres)
    .map((b) => ({ ...b, litres: npr(b.litres, 2), spend: npr(b.spend, 2), rate: npr(b.rate, 2) }));

  const ivOut = iv.map(({ unknown, ...r }) => Object.fromEntries(Object.entries(r).map(([k, v]) =>
    [k, typeof v === "number" && k !== "trips" && k !== "fills" ? npr(v, 3) : v])));

  return nanToNull({
    source,
    constants: { tank_l: TANK_L, arai_kmpl: ARAI_KMPL, brim_l: BRIM_L, hwy_kmh: HWY_KMH, premium_markup: PREMIUM_MARKUP },
    calibration: cal,
    fills: f.map((r) => ({
      date: r.date.slice(0, 10), moment: r.moment == null ? null : isoOf(r.moment), station: r.station, brand: r.brand,
      litres: rnd(r.litres, 2), amount: rnd(r.amount, 2), rate: rnd(r.rate, 2), premium: !!r.premium, imputed: r.imputed || null,
      logged_km: r.logged_km, odo: rnd(r.odo, 1), brim: r.brim, over_tank: r.over_tank,
    })),
    intervals: ivOut,
    model,
    missing,
    totals,
    monthly: [...months].sort((a, b) => (a[0] < b[0] ? -1 : 1)).map(([month, s]) => ({
      month, km: rnd(s.km, 1), est_l: rnd(s.est_l, 2), est_cost: rnd(s.est_cost), idle_cost: rnd(s.idle_cost),
      spend: rnd(s.spend), litres: rnd(s.litres, 2) })),
    brands,
    trips: t.map((r) => ({
      id: r.trip_id, start: r.start_ts, km: rnd(r.km_adj, 2), est_l: rnd(r.est_l, 3), idle_l: rnd(r.idle_l, 3),
      cost: rnd(r.est_cost, 1), kmpl: rnd(r.kmpl_est, 2), hwy: r.hwy, avg: r.avg_kmh,
      idle_share: r.drive_min + r.idle_min ? rnd(r.idle_min / (r.drive_min + r.idle_min), 3) : 0,
    })),
    fuel_level: snaps.filter((r) => isNum(r.fuel_pct)).map((r) => [r.taken_at, r.fuel_pct, r.range_km]),
    tank: tankLevel(t, f, iv, model, snaps),
  });
}
