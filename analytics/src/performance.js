// Performance-engineering analytics. Port of performance.py -> web/performance.json.
// k-means / PCA cannot match sklearn bit for bit: k-means++ with a seeded mulberry32 PRNG, PCA by Jacobi.
import { breadcrumbTimes } from "./tables.js";
import { groupBy, haversineKm, inv, lstsq, median, npRound, pyRound, quantile } from "./util.js";

export const COLD_SOAK_H = 4.0;
export const STOP_KMH = 3.0, MOVE_KMH = 10.0;
export const BANDS = [[0, 5, "Stopped"], [5, 20, "5–20"], [20, 40, "20–40"], [40, 60, "40–60"],
  [60, 80, "60–80"], [80, 100, "80–100"], [100, 999, "100+"]];
export const WLTC = [["Low", 18.9, 56.5], ["Medium", 39.5, 76.6], ["High", 56.7, 97.4], ["Extra high", 91.7, 131.3]];
export const K = 3;
export const CLUSTER_FEATURES = ["log_km", "overall_kmh", "idle_share", "max_kmh", "log_min"];

const DAY = 86400000;
const num = (v) => (v == null ? NaN : v);
const ok = (v) => v != null && !Number.isNaN(v);
const sum = (xs) => xs.reduce((a, b) => a + b, 0);
const mean = (xs) => sum(xs) / xs.length;
const variance = (xs, ddof = 0) => { const m = mean(xs); return sum(xs.map((x) => (x - m) ** 2)) / (xs.length - ddof); };
const ms = (iso) => Date.parse(iso + "Z");
const dayIso = (msv) => new Date(msv).toISOString().slice(0, 10);
const dow = (msv) => (new Date(msv).getUTCDay() + 6) % 7; // Monday = 0
const hourFrac = (msv) => { const d = new Date(msv); return d.getUTCHours() + d.getUTCMinutes() / 60; };
const nr = (xs, d) => xs.map((x) => npRound(x, d));
const by = (xs, f) => [...xs].sort((a, b) => f(a) - f(b));
const ascKeys = (m) => [...m.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

export function tripFeatures(trips, delta) {
  const t = trips.map((r) => ({ ...r })).sort((a, b) => (a.start_ts < b.start_ts ? -1 : a.start_ts > b.start_ts ? 1 : 0));
  let prevEnd = null;
  for (const r of t) {
    const s = ms(r.start_ts), e = r.end_ts == null ? NaN : ms(r.end_ts);
    r.km = r.distance_km + delta;
    r.elapsed_min = (e - s) / 60000;
    r.engine_min = r.drive_min + r.idle_min;
    r.idle_share = r.engine_min > 0 ? r.idle_min / r.engine_min : 0;
    r.overall_kmh = r.km / (Math.max(r.elapsed_min, 1) / 60);
    r.soak_h = prevEnd == null ? NaN : (s - prevEnd) / 3600000;
    r.cold = Number.isNaN(r.soak_h) || r.soak_h >= COLD_SOAK_H;
    r.hour = hourFrac(s);
    r.wd = dow(s);
    r.events = num(r.hard_brake) + num(r.rapid_accel) + num(r.overspeed);
    r.log_km = Math.log1p(r.km);
    r.log_min = Math.log1p(r.elapsed_min);
    r.max_kmh = num(r.max_kmh);
    r.avg_kmh = num(r.avg_kmh);
    prevEnd = e;
  }
  return t;
}

const bandOf = (v) => BANDS.findIndex(([lo, hi]) => v >= lo && v < hi);

/** Per-trip drive-cycle metrics plus the pooled speed-acceleration distribution. */
export function gpsFeatures(points) {
  const p = breadcrumbTimes(points).map(({ r, tsSec, offNs }) => ({ trip_id: r.trip_id, tm: (tsSec + offNs / 1e9) * 1000, speed: r.speed }));
  p.sort((a, b) => (a.trip_id < b.trip_id ? -1 : a.trip_id > b.trip_id ? 1 : a.tm - b.tm));
  let prev = null;
  for (const r of p) {
    if (prev && prev.trip_id === r.trip_id) {
      r.dt = Math.min((r.tm - prev.tm) / 1000, 30);
      r.acc = r.dt > 0 ? Math.min(Math.max((r.speed / 3.6 - prev.speed / 3.6) / r.dt, -3), 3) : 0;
    } else { r.dt = 0; r.acc = 0; }
    r.band = bandOf(r.speed);
    prev = r;
  }
  const rows = [];
  for (const [tid, g] of groupBy(p, (r) => r.trip_id)) {
    const secs = sum(g.map((r) => r.dt));
    if (secs <= 0) continue;
    const distM = sum(g.map((r) => (r.speed / 3.6) * r.dt));
    let moving = false, stops = 0;
    for (const { speed: s } of g) {
      if (s >= MOVE_KMH) moving = true;
      else if (s < STOP_KMH && moving) { stops++; moving = false; }
    }
    const rpa = distM > 50 ? sum(g.map((r) => (r.speed / 3.6) * Math.max(r.acc, 0) * r.dt)) / distM : NaN;
    const row = { trip_id: tid, rpa, stops, stops_per_km: distM > 200 ? stops / (distM / 1000) : NaN,
      p95_kmh: quantile(g.map((r) => r.speed), 0.95), gps_secs: secs };
    BANDS.forEach(([, , name], i) => { row[`band_${name}`] = sum(g.filter((r) => r.band === i).map((r) => r.dt)) / secs; });
    rows.push(row);
  }

  // Pooled speed x acceleration occupancy (seconds), moving samples only.
  const vb = Array.from({ length: 15 }, (_, i) => i * 10);
  const ab = Array.from({ length: 13 }, (_, i) => npRound(-1.5 + i * 0.25, 2));
  const h = Array.from({ length: 14 }, () => new Array(12).fill(0));
  for (const r of p) {
    if (!(r.speed >= 2)) continue;
    const s = Math.min(Math.max(r.speed, 0), 139.9), a = Math.min(Math.max(r.acc, -1.499), 1.499);
    h[Math.floor(s / 10)][Math.floor((a + 1.5) / 0.25)] += r.dt;
  }
  const va = { speed_edges: vb, acc_edges: ab, seconds: h.map((row) => nr(row, 1)) };

  const tot = BANDS.map((_, i) => sum(p.filter((r) => r.band === i).map((r) => r.dt)));
  const all = sum(tot);
  const pooled = { bands: BANDS.map((b) => b[2]), share: nr(tot.map((v) => v / all), 4) };
  return { gf: rows, va, pooled };
}

// ---------- clustering ----------

export function mulberry32(a) {
  return () => {
    a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const d2 = (a, b) => { let s = 0; for (let i = 0; i < a.length; i++) s += (a[i] - b[i]) ** 2; return s; };

function kmeansOnce(X, k, rnd) {
  const n = X.length, dim = X[0].length;
  // k-means++ seeding (D^2 sampling)
  const centers = [X[Math.floor(rnd() * n)].slice()];
  const near = X.map((x) => d2(x, centers[0]));
  while (centers.length < k) {
    const total = sum(near);
    let r = rnd() * total, i = 0;
    for (; i < n - 1; i++) { r -= near[i]; if (r <= 0) break; }
    centers.push(X[i].slice());
    for (let j = 0; j < n; j++) near[j] = Math.min(near[j], d2(X[j], centers[centers.length - 1]));
  }
  const labels = new Array(n).fill(-1);
  for (let iter = 0; iter < 300; iter++) {
    let changed = false;
    for (let i = 0; i < n; i++) {
      let best = 0, bd = Infinity;
      for (let c = 0; c < k; c++) { const d = d2(X[i], centers[c]); if (d < bd) { bd = d; best = c; } }
      if (labels[i] !== best) { labels[i] = best; changed = true; }
    }
    if (!changed) break;
    const cnt = new Array(k).fill(0), acc = Array.from({ length: k }, () => new Array(dim).fill(0));
    X.forEach((x, i) => { cnt[labels[i]]++; for (let j = 0; j < dim; j++) acc[labels[i]][j] += x[j]; });
    for (let c = 0; c < k; c++) {
      if (cnt[c]) centers[c] = acc[c].map((v) => v / cnt[c]);
      else { // empty cluster: take the point farthest from its centre
        let far = 0, fd = -1;
        X.forEach((x, i) => { const d = d2(x, centers[labels[i]]); if (d > fd) { fd = d; far = i; } });
        centers[c] = X[far].slice();
      }
    }
  }
  return { labels, inertia: sum(X.map((x, i) => d2(x, centers[labels[i]]))) };
}

/** Lowest-inertia of nInit k-means++ runs; one seeded PRNG stream. */
export function kmeans(X, k, nInit, seed = 0) {
  const rnd = mulberry32(seed);
  let best = null;
  for (let i = 0; i < nInit; i++) {
    const r = kmeansOnce(X, k, rnd);
    if (!best || r.inertia < best.inertia) best = r;
  }
  return best.labels;
}

/** sklearn silhouette_score (euclidean, all samples). */
export function silhouette(X, labels) {
  const n = X.length, k = Math.max(...labels) + 1;
  const size = new Array(k).fill(0);
  labels.forEach((l) => size[l]++);
  let total = 0;
  for (let i = 0; i < n; i++) {
    const s = new Array(k).fill(0);
    for (let j = 0; j < n; j++) if (j !== i) s[labels[j]] += Math.sqrt(d2(X[i], X[j]));
    if (size[labels[i]] <= 1) continue; // singleton: 0
    const a = s[labels[i]] / (size[labels[i]] - 1);
    let b = Infinity;
    for (let c = 0; c < k; c++) if (c !== labels[i] && size[c]) b = Math.min(b, s[c] / size[c]);
    total += (b - a) / Math.max(a, b);
  }
  return total / n;
}

/** Symmetric eigen-decomposition by cyclic Jacobi. Returns eigenvalues (descending) and matching unit eigenvectors (rows). */
export function jacobiEigen(S) {
  const n = S.length;
  const A = S.map((r) => [...r]);
  const V = Array.from({ length: n }, (_, i) => Array.from({ length: n }, (_, j) => (i === j ? 1 : 0)));
  for (let sweep = 0; sweep < 100; sweep++) {
    let off = 0;
    for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) off += A[i][j] ** 2;
    if (off < 1e-30) break;
    for (let p = 0; p < n - 1; p++) {
      for (let q = p + 1; q < n; q++) {
        if (Math.abs(A[p][q]) < 1e-300) continue;
        const theta = (A[q][q] - A[p][p]) / (2 * A[p][q]);
        const t = Math.sign(theta || 1) / (Math.abs(theta) + Math.sqrt(theta * theta + 1));
        const c = 1 / Math.sqrt(t * t + 1), s = t * c;
        for (let k = 0; k < n; k++) {
          const akp = A[k][p], akq = A[k][q];
          A[k][p] = c * akp - s * akq; A[k][q] = s * akp + c * akq;
        }
        for (let k = 0; k < n; k++) {
          const apk = A[p][k], aqk = A[q][k];
          A[p][k] = c * apk - s * aqk; A[q][k] = s * apk + c * aqk;
        }
        for (let k = 0; k < n; k++) {
          const vkp = V[k][p], vkq = V[k][q];
          V[k][p] = c * vkp - s * vkq; V[k][q] = s * vkp + c * vkq;
        }
      }
    }
  }
  const order = [...Array(n).keys()].sort((a, b) => A[b][b] - A[a][a]);
  return { values: order.map((i) => A[i][i]), vectors: order.map((i) => V.map((row) => row[i])) };
}

/** PCA of already-centred X. Component sign: largest-|loading| entry positive. */
function pca(X, nComp = 2) {
  const n = X.length, d = X[0].length;
  const cov = Array.from({ length: d }, (_, i) => Array.from({ length: d }, (_, j) => sum(X.map((r) => r[i] * r[j])) / (n - 1)));
  const { values, vectors } = jacobiEigen(cov);
  for (const v of vectors) {
    let big = 0;
    v.forEach((x, i) => { if (Math.abs(x) > Math.abs(v[big])) big = i; });
    if (v[big] < 0) for (let i = 0; i < d; i++) v[i] = -v[i];
  }
  const total = sum(values);
  return {
    components: vectors.slice(0, nComp), variance: values.slice(0, nComp), ratio: values.slice(0, nComp).map((v) => v / total),
    transform: (x) => vectors.slice(0, nComp).map((v) => sum(v.map((c, i) => c * x[i]))),
  };
}

function nameCluster(r) {
  if (r.overall_kmh >= 40 || r.max_kmh >= 85) return "Highway runs";
  if (r.km < 4) return "Short hops";
  if (r.idle_share >= 0.33) return "Stop-and-go";
  return "City trips";
}

export function cluster(t) {
  // StandardScaler: population SD (ddof 0)
  const cols = CLUSTER_FEATURES.map((f) => t.map((r) => r[f]));
  const mu = cols.map(mean), sd = cols.map((c) => Math.sqrt(variance(c)));
  const X = t.map((r, i) => cols.map((c, j) => (sd[j] ? (c[i] - mu[j]) / sd[j] : 0)));
  const silh = {};
  for (let k = 2; k <= 6; k++) silh[k] = silhouette(X, kmeans(X, k, 20));
  const raw = kmeans(X, K, 50);
  const model = pca(X, 2);

  const ids = [...new Set(raw)].sort((a, b) => a - b);
  const prof = new Map(ids.map((c) => {
    const g = t.filter((_, i) => raw[i] === c);
    const col = (f) => g.map((r) => r[f]);
    return [c, { n: g.length, km: median(col("km")), overall_kmh: median(col("overall_kmh")), idle_share: median(col("idle_share")),
      max_kmh: median(col("max_kmh")), minutes: median(col("elapsed_min")), km_total: sum(col("km")) }];
  }));
  const names = new Map(ids.map((c) => [c, nameCluster(prof.get(c))]));
  const seen = {};
  for (const c of by(ids, (c) => -prof.get(c).km)) { // disambiguate duplicates (as performance.py: always "shorter")
    const nm = names.get(c);
    seen[nm] = (seen[nm] ?? 0) + 1;
    if (seen[nm] > 1) names.set(c, `${nm} (shorter)`);
  }
  // Stable display order: highway first (fastest overall speed)
  const order = by(ids, (c) => -prof.get(c).overall_kmh);
  const remap = new Map(order.map((old, i) => [old, i]));
  const kmTotal = sum(ids.map((c) => prof.get(c).km_total));
  const profiles = order.map((old, i) => {
    const r = prof.get(old);
    const o = { cluster: i, name: names.get(old) };
    for (const [k, v] of Object.entries({ ...r, share_km: r.km_total / kmTotal })) o[k] = pyRound(v, 3);
    return o;
  });

  const out = t.map((r, i) => {
    const [pc1, pc2] = model.transform(X[i]);
    return { ...r, cluster: remap.get(raw[i]), pc1, pc2 };
  });
  const loadings = {};
  CLUSTER_FEATURES.forEach((f, i) => { loadings[f] = model.components.map((c, j) => npRound(c[i] * Math.sqrt(model.variance[j]), 3)); });
  return {
    t: out,
    clusters: { k: K, silhouette: silh, features: CLUSTER_FEATURES, explained_variance: nr(model.ratio, 4), loadings, profiles },
  };
}

// ---------- power law / commute / forecast / cold / correlations ----------

/** log(minutes) = a + b log(km): how trip time scales with distance; outliers by studentized residual. */
export function powerLaw(t) {
  const d = t.filter((r) => r.km >= 1 && r.elapsed_min >= 2);
  const x = d.map((r) => Math.log(r.km)), y = d.map((r) => Math.log(r.elapsed_min));
  const X = x.map((v) => [1, v]);
  const beta = lstsq(X, y);
  const fit = X.map((r) => r[0] * beta[0] + r[1] * beta[1]);
  const res = y.map((v, i) => v - fit[i]);
  const n = X.length, k = 2;
  const s = Math.sqrt(sum(res.map((r) => r * r)) / (n - k));
  const XtXi = inv([[sum(X.map((r) => r[0] * r[0])), sum(X.map((r) => r[0] * r[1]))], [sum(X.map((r) => r[1] * r[0])), sum(X.map((r) => r[1] * r[1]))]]);
  const quad = (r) => r[0] * (XtXi[0][0] * r[0] + XtXi[0][1] * r[1]) + r[1] * (XtXi[1][0] * r[0] + XtXi[1][1] * r[1]);
  const stud = X.map((r, i) => res[i] / (s * Math.sqrt(1 - quad(r))));
  const lo = Math.min(...x), hi = Math.max(...x), step = (hi - lo) / 59;
  const gx = Array.from({ length: 60 }, (_, i) => (i === 59 ? hi : lo + i * step));
  const G = gx.map((v) => [1, v]);
  const gfit = G.map((r) => r[0] * beta[0] + r[1] * beta[1]);
  const se = G.map((r) => s * Math.sqrt(1 + quad(r)));
  const top = d.map((r, i) => ({ r, stud: stud[i], expected: Math.exp(fit[i]) }))
    .filter((o) => Math.abs(o.stud) > 2.5).sort((a, b) => b.stud - a.stud);
  return {
    a: beta[0], b: beta[1], s, r2: 1 - variance(res) / variance(y), n,
    band: {
      km: nr(gx.map(Math.exp), 3), fit: nr(gfit.map(Math.exp), 2),
      lo: nr(gfit.map((v, i) => Math.exp(v - 1.96 * se[i])), 2), hi: nr(gfit.map((v, i) => Math.exp(v + 1.96 * se[i])), 2),
    },
    outliers: top.map(({ r, stud: sv, expected }) => ({
      id: r.trip_id, start: r.start_ts, km: pyRound(r.km, 1), minutes: pyRound(r.elapsed_min, 0),
      expected: pyRound(expected, 0), stud: pyRound(sv, 2), idle_min: r.idle_min,
    })),
  };
}

export function commuteReliability(t) {
  const out = {};
  for (const [key, a, b] of [["to_work", "Home", "Work"], ["to_home", "Work", "Home"]]) {
    const d = t.filter((r) => r.from_place === a && r.to_place === b);
    if (d.length < 8) continue;
    const m = d.map((r) => r.elapsed_min);
    const p5 = quantile(m, 0.05), p50 = median(m), p95 = quantile(m, 0.95), mu = mean(m);
    const slots = groupBy(d, (r) => Math.floor(hourFrac(ms(r.start_ts)) * 4) / 4);
    const bySlot = ascKeys(slots).filter((s) => slots.get(s).length >= 2).map((s) => {
      const e = slots.get(s).map((r) => r.elapsed_min);
      return [s, median(e), e.length, quantile(e, 0.25), quantile(e, 0.75)];
    });
    const wds = groupBy(d, (r) => dow(ms(r.start_ts)));
    out[key] = {
      n: d.length, free_flow: p5, median: p50, mean: mu, p95, pti: p95 / p5, bti: (p95 - mu) / mu,
      km: median(d.map((r) => r.km)), minutes: nr(m, 1), by_slot: bySlot,
      by_weekday: ascKeys(wds).map((w) => [w, median(wds.get(w).map((r) => r.elapsed_min))]),
      trips: d.map((r) => [r.start_ts, pyRound(r.elapsed_min, 1), pyRound(r.idle_min / Math.max(r.engine_min, 1), 3)]),
    };
  }
  return Object.keys(out).length ? out : null;
}

/** Odometer forecast: daily km i.i.d. over the recent window, uncertainty in the mean included. */
export function forecast(t, odoNow, today, horizon = 240, windowDays = 120) {
  const perDay = new Map();
  for (const r of t) perDay.set(r.start_ts.slice(0, 10), (perDay.get(r.start_ts.slice(0, 10)) ?? 0) + r.km);
  const first = ms(ascKeys(perDay)[0] + "T00:00:00"), last = ms(today + "T00:00:00");
  const nDays = Math.round((last - first) / DAY) + 1;
  const days = Array.from({ length: nDays }, (_, i) => first + i * DAY);
  const daily = days.map((d) => perDay.get(dayIso(d)) ?? 0);
  const odo = new Array(nDays);
  let after = 0;
  for (let i = nDays - 1; i >= 0; i--) { odo[i] = odoNow - after; after += daily[i]; }
  const recent = daily.slice(-windowDays);
  const mu = mean(recent), sd = Math.sqrt(variance(recent, 1)), n = recent.length;
  const h = Array.from({ length: horizon }, (_, i) => i + 1);
  const mn = h.map((v) => odoNow + mu * v);
  const spread = h.map((v) => Math.sqrt(v * sd ** 2 + ((v * sd) / Math.sqrt(n)) ** 2));
  const future = h.map((v) => last + v * DAY);
  const cross = (level, series) => { const i = series.findIndex((v) => v >= level); return i < 0 ? null : dayIso(future[i]); };
  const milestones = [];
  for (let level = (Math.floor(odoNow / 5000) + 1) * 5000; level < Math.trunc(mn[horizon - 1]) + 1; level += 5000) {
    milestones.push({ km: level, p50: cross(level, mn), early: cross(level, mn.map((m, i) => m + 1.2816 * spread[i])),
      late: cross(level, mn.map((m, i) => m - 1.2816 * spread[i])) });
  }
  const weekly = new Map(); // W-SUN: label = the Sunday on or after the day
  days.forEach((d, i) => { const lab = d + ((6 - dow(d)) % 7) * DAY; weekly.set(lab, (weekly.get(lab) ?? 0) + daily[i]); });
  return {
    history: days.map((d, i) => [dayIso(d), pyRound(odo[i], 1)]),
    future: future.map((d, i) => [dayIso(d), pyRound(mn[i], 1), pyRound(mn[i] - 1.2816 * spread[i], 1), pyRound(mn[i] + 1.2816 * spread[i], 1)]),
    km_per_day: mu, sd_per_day: sd, window_days: windowDays, milestones,
    weekly: [...weekly].sort((a, b) => a[0] - b[0]).map(([d, v]) => [dayIso(d), pyRound(v, 1)]),
  };
}

export function coldStarts(t) {
  const edges = [0, 1 / 6, 0.5, 1, 2, 4, 8, 16, 1e9];
  const labels = ["<10 min", "10–30 min", "30–60 min", "1–2 h", "2–4 h", "4–8 h", "8–16 h", "16 h+"];
  const counts = new Array(8).fill(0);
  for (const r of t) if (ok(r.soak_h)) { const i = edges.findIndex((e, k) => k < 8 && r.soak_h >= e && r.soak_h < edges[k + 1]); if (i >= 0) counts[i]++; }
  const shortCold = t.filter((r) => r.cold && r.km < 5);
  return {
    labels, counts, cold_share: t.filter((r) => r.cold).length / t.length, short_cold: shortCold.length,
    short_cold_share: shortCold.length / t.length, short_cold_km: sum(shortCold.map((r) => r.km)), threshold_h: COLD_SOAK_H,
  };
}

/** Average-rank (scipy/pandas "average"); NaN stays NaN. */
function rank(xs) {
  const idx = xs.map((v, i) => i).filter((i) => ok(xs[i])).sort((a, b) => xs[a] - xs[b]);
  const out = xs.map(() => NaN);
  for (let i = 0; i < idx.length;) {
    let j = i;
    while (j + 1 < idx.length && xs[idx[j + 1]] === xs[idx[i]]) j++;
    for (let k = i; k <= j; k++) out[idx[k]] = (i + j) / 2 + 1;
    i = j + 1;
  }
  return out;
}

export function correlations(t) {
  const cols = { km: "Distance", elapsed_min: "Duration", avg_kmh: "Moving speed", overall_kmh: "Overall speed",
    max_kmh: "Top speed", idle_share: "Idle share", hour: "Start hour", soak_h: "Soak time", events: "Alerts" };
  const keys = Object.keys(cols);
  const ranks = keys.map((k) => rank(t.map((r) => r[k]))); // pandas ranks each column, then correlates pairwise-complete
  const pear = (a, b) => {
    const ix = a.map((_, i) => i).filter((i) => ok(a[i]) && ok(b[i]));
    const xa = ix.map((i) => a[i]), xb = ix.map((i) => b[i]);
    const ma = mean(xa), mb = mean(xb);
    const cov = sum(xa.map((v, i) => (v - ma) * (xb[i] - mb)));
    return cov / Math.sqrt(sum(xa.map((v) => (v - ma) ** 2)) * sum(xb.map((v) => (v - mb) ** 2)));
  };
  return { labels: Object.values(cols), matrix: ranks.map((a, i) => ranks.map((b, j) => npRound(i === j ? 1 : pear(a, b), 3))) };
}

// ---------- build ----------

const cleanOut = (o) => {
  if (Array.isArray(o)) return o.map(cleanOut);
  if (o && typeof o === "object") return Object.fromEntries(Object.entries(o).map(([k, v]) => [k, cleanOut(v)]));
  return typeof o === "number" && !Number.isFinite(o) ? null : o;
};

const pad2 = (n) => String(n).padStart(2, "0");
const localIso = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}T${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;

/** tables = loadTables(files) (trips carry from_place/to_place once buildOverview has run).
 *  opts: today 'YYYY-MM-DD', odoNow, delta (km added per trip), fuelModel (buildFuel().model or null). */
export function buildPerformance(tables, { today, odoNow, delta, fuelModel = null, now = new Date() }) {
  const { trips, points } = tables;
  let t = tripFeatures(trips, delta);
  const hasGps = points.length > 0;
  let gf = [], va = null, pooled = null;
  if (hasGps) ({ gf, va, pooled } = gpsFeatures(points));
  const gfBy = new Map(gf.map((r) => [r.trip_id, r]));
  if (gf.length) {
    const blank = { rpa: NaN, stops: NaN, stops_per_km: NaN, p95_kmh: NaN, gps_secs: NaN, ...Object.fromEntries(BANDS.map((b) => [`band_${b[2]}`, NaN])) };
    t = t.map((r) => ({ ...(gfBy.get(r.trip_id) ?? blank), ...r }));
  }
  const clustered = cluster(t);
  t = clustered.t;
  const routed = gf.length ? t.filter((r) => ok(r.rpa)) : [];

  const bandCols = BANDS.map((b) => `band_${b[2]}`);
  const byCluster = [];
  if (routed.length) {
    const g = groupBy(routed, (r) => r.cluster);
    for (const c of [...g.keys()].sort((a, b) => a - b)) {
      const rows = g.get(c), w = rows.map((r) => r.gps_secs);
      byCluster.push({ cluster: c, n: rows.length, share: bandCols.map((col) => sum(rows.map((r, i) => r[col] * w[i])) / sum(w)) });
    }
  }

  const months = groupBy(t, (r) => r.start_ts.slice(0, 7));
  const monthly = ascKeys(months).map((m) => {
    const g = months.get(m);
    const v = {
      km: sum(g.map((r) => r.km)), trips: g.length, moving_kmh: median(g.map((r) => r.avg_kmh)), overall_kmh: median(g.map((r) => r.overall_kmh)),
      idle_share: median(g.map((r) => r.idle_share)), engine_h: sum(g.map((r) => r.engine_min)) / 60, events: sum(g.map((r) => r.events)),
    };
    return { month: m, ...Object.fromEntries(Object.entries(v).map(([k, x]) => [k, pyRound(x, 3)])) };
  });

  let idleFuel = null;
  if (fuelModel) {
    const c = fuelModel.coef;
    idleFuel = { lph: c.idle_lph, litres: (sum(t.map((r) => r.idle_min)) / 60) * c.idle_lph };
  }

  const keep = ["trip_id", "start_ts", "km", "elapsed_min", "avg_kmh", "overall_kmh", "max_kmh", "idle_share", "soak_h",
    "cold", "cluster", "pc1", "pc2", "events", "rpa", "stops_per_km", "p95_kmh", ...bandCols].filter((k) => k in t[0]);
  const tripsOut = t.map((r) => Object.fromEntries(keep.map((k) => [k, typeof r[k] === "number" && !Number.isInteger(r[k]) ? npRound(r[k], 4) : r[k]])));
  const engineH = sum(t.map((r) => r.engine_min)) / 60;
  const kmAll = sum(t.map((r) => r.km));
  return cleanOut({
    generated_at: localIso(now),
    delta_km_per_trip: delta,
    totals: {
      trips: t.length, km: kmAll, engine_h: engineH, km_per_engine_h: kmAll / engineH, routed: routed.length,
      rpa_median: routed.length ? median(routed.map((r) => r.rpa)) : null,
      stops_per_km_median: routed.length ? median(routed.map((r) => r.stops_per_km)) : null,
      idle_h: sum(t.map((r) => r.idle_min)) / 60,
    },
    trips: tripsOut,
    wltc: WLTC.map(([phase, a, m]) => ({ phase, avg_kmh: a, max_kmh: m })),
    speed_bands: pooled,
    bands_by_cluster: byCluster,
    speed_accel: va,
    clusters: clustered.clusters,
    power_law: powerLaw(t),
    commute: t.some((r) => "from_place" in r) ? commuteReliability(t) : null,
    forecast: forecast(t, odoNow, today),
    cold: coldStarts(t),
    correlations: correlations(t),
    monthly,
    idle_fuel: idleFuel,
  });
}
