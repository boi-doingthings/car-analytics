// Small numeric / formatting helpers matching Python / pandas / numpy semantics.

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
  "September", "October", "November", "December"];

/** Python f"{x:.{d}f}": exact-decimal rounding, ties to even (JS toFixed rounds exact ties up). */
export function fmtFixed(x, d = 0) {
  if (Number.isNaN(x)) return "nan";
  if (!Number.isFinite(x)) return x < 0 ? "-inf" : "inf";
  const neg = x < 0 || Object.is(x, -0);
  const a = Math.abs(x);
  const wide = a.toFixed(d + 25);
  let out;
  if (wide.endsWith("5" + "0".repeat(24))) {
    const head = wide.slice(0, -25).replace(/\.$/, "");
    out = Number(head[head.length - 1]) % 2 === 0 ? head : a.toFixed(d);
  } else {
    out = a.toFixed(d);
  }
  return (neg ? "-" : "") + out;
}

/** Python f"{x:,.0f}". */
export function fmtInt(x) {
  const s = fmtFixed(x, 0);
  const m = /^(-?)(\d+)$/.exec(s);
  return m ? m[1] + m[2].replace(/\B(?=(\d{3})+$)/g, ",") : s;
}

/** strftime subset on an ISO date/datetime string: %-d %d %B %b %m %Y %y. */
export function fmtDate(iso, pattern) {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  const map = {
    "%-d": String(d), "%d": String(d).padStart(2, "0"),
    "%B": MONTHS[m - 1], "%b": MONTHS[m - 1].slice(0, 3),
    "%m": String(m).padStart(2, "0"), "%Y": String(y), "%y": String(y % 100).padStart(2, "0"),
    "%%": "%",
  };
  return pattern.replace(/%-d|%[dBbmYy%]/g, (t) => map[t]);
}

export function haversineKm(lat1, lon1, lat2, lon2) {
  const r = Math.PI / 180;
  const p1 = lat1 * r, p2 = lat2 * r;
  const a = Math.sin((p2 - p1) / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(((lon2 - lon1) * r) / 2) ** 2;
  return 6371 * 2 * Math.asin(Math.sqrt(a));
}

/** Map key -> items, keys in first-seen order. */
export function groupBy(items, keyFn) {
  const m = new Map();
  for (const it of items) {
    const k = keyFn(it);
    if (!m.has(k)) m.set(k, []);
    m.get(k).push(it);
  }
  return m;
}

const clean = (xs) => xs.filter((v) => v != null && !Number.isNaN(v)).sort((a, b) => a - b);

/** pandas-style quantile (linear interpolation, NaN/null skipped); NaN when empty. */
export function quantile(xs, q) {
  const s = clean(xs);
  if (!s.length) return NaN;
  const pos = (s.length - 1) * q;
  const lo = Math.floor(pos), hi = Math.ceil(pos);
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

/** Median; even count -> mean of the middle two. */
export function median(xs) {
  const s = clean(xs);
  if (!s.length) return NaN;
  const h = s.length >> 1;
  return s.length % 2 ? s[h] : (s[h - 1] + s[h]) / 2;
}

/** Solve A x = b (square) by Gaussian elimination with partial pivoting. b may be a vector or matrix (array of rows). */
export function solve(A, b) {
  const n = A.length;
  const vec = !Array.isArray(b[0]);
  const M = A.map((row, i) => [...row, ...(vec ? [b[i]] : b[i])]);
  for (let c = 0; c < n; c++) {
    let p = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
    if (Math.abs(M[p][c]) < 1e-300) throw new Error("singular matrix");
    [M[c], M[p]] = [M[p], M[c]];
    for (let r = c + 1; r < n; r++) {
      const f = M[r][c] / M[c][c];
      if (f) for (let k = c; k < M[r].length; k++) M[r][k] -= f * M[c][k];
    }
  }
  const w = M[0].length - n;
  const X = Array.from({ length: n }, () => new Array(w).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = 0; j < w; j++) {
      let s = M[i][n + j];
      for (let k = i + 1; k < n; k++) s -= M[i][k] * X[k][j];
      X[i][j] = s / M[i][i];
    }
  }
  return vec ? X.map((r) => r[0]) : X;
}

export function inv(A) {
  const n = A.length;
  return solve(A, A.map((_, i) => Array.from({ length: n }, (_, j) => (i === j ? 1 : 0))));
}

/** Least squares min ||X beta - y|| via Householder QR (X: m x n rows, m >= n, full column rank). */
export function lstsq(X, y) {
  const m = X.length, n = X[0].length;
  const R = X.map((r) => [...r]);
  const q = [...y];
  for (let k = 0; k < n; k++) {
    let norm = 0;
    for (let i = k; i < m; i++) norm += R[i][k] ** 2;
    norm = Math.sqrt(norm);
    if (norm < 1e-300) throw new Error("rank deficient");
    const alpha = R[k][k] > 0 ? -norm : norm;
    const v = new Array(m).fill(0);
    for (let i = k; i < m; i++) v[i] = R[i][k];
    v[k] -= alpha;
    const vv = v.reduce((s, t) => s + t * t, 0);
    if (vv === 0) continue;
    for (let j = k; j < n; j++) {
      let d = 0;
      for (let i = k; i < m; i++) d += v[i] * R[i][j];
      const f = (2 * d) / vv;
      for (let i = k; i < m; i++) R[i][j] -= f * v[i];
    }
    let d = 0;
    for (let i = k; i < m; i++) d += v[i] * q[i];
    const f = (2 * d) / vv;
    for (let i = k; i < m; i++) q[i] -= f * v[i];
  }
  const beta = new Array(n).fill(0);
  for (let i = n - 1; i >= 0; i--) {
    let s = q[i];
    for (let k = i + 1; k < n; k++) s -= R[i][k] * beta[k];
    if (Math.abs(R[i][i]) < 1e-12 * Math.max(1, ...R[0].map(Math.abs))) throw new Error("rank deficient");
    beta[i] = s / R[i][i];
  }
  return beta;
}

/** numpy rint: round half to even. */
export function rint(v) {
  const r = Math.round(v);
  return Math.abs(v % 1) === 0.5 && r % 2 !== 0 ? r - 1 : r;
}

/** Python builtin round(x, d) on a float: exact decimal value, ties to even. */
export function pyRound(x, d = 0) {
  return Number.isFinite(x) ? Number(fmtFixed(x, d)) : x;
}

/** numpy round(x, d) (np.float64.__round__): rint(x * 10^d) / 10^d. */
export function npRound(x, d = 0) {
  return Number.isFinite(x) ? rint(x * 10 ** d) / 10 ** d : x;
}

/** Python f"{x:.{d}%}". */
export function fmtPercent(x, d = 0) {
  return fmtFixed(x * 100, d) + "%";
}
