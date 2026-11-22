var __i20 = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // src/index.js
  var index_exports = {};
  __export(index_exports, {
    runAll: () => runAll
  });

  // src/util.js
  var MONTHS = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December"
  ];
  function fmtFixed(x, d = 0) {
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
  function fmtInt(x) {
    const s = fmtFixed(x, 0);
    const m = /^(-?)(\d+)$/.exec(s);
    return m ? m[1] + m[2].replace(/\B(?=(\d{3})+$)/g, ",") : s;
  }
  function fmtDate(iso, pattern) {
    const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
    const map = {
      "%-d": String(d),
      "%d": String(d).padStart(2, "0"),
      "%B": MONTHS[m - 1],
      "%b": MONTHS[m - 1].slice(0, 3),
      "%m": String(m).padStart(2, "0"),
      "%Y": String(y),
      "%y": String(y % 100).padStart(2, "0"),
      "%%": "%"
    };
    return pattern.replace(/%-d|%[dBbmYy%]/g, (t) => map[t]);
  }
  function haversineKm(lat1, lon1, lat2, lon2) {
    const r = Math.PI / 180;
    const p1 = lat1 * r, p2 = lat2 * r;
    const a = Math.sin((p2 - p1) / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin((lon2 - lon1) * r / 2) ** 2;
    return 6371 * 2 * Math.asin(Math.sqrt(a));
  }
  function groupBy(items, keyFn) {
    const m = /* @__PURE__ */ new Map();
    for (const it of items) {
      const k = keyFn(it);
      if (!m.has(k)) m.set(k, []);
      m.get(k).push(it);
    }
    return m;
  }
  var clean = (xs) => xs.filter((v) => v != null && !Number.isNaN(v)).sort((a, b) => a - b);
  function quantile(xs, q) {
    const s = clean(xs);
    if (!s.length) return NaN;
    const pos = (s.length - 1) * q;
    const lo = Math.floor(pos), hi = Math.ceil(pos);
    return s[lo] + (s[hi] - s[lo]) * (pos - lo);
  }
  function median(xs) {
    const s = clean(xs);
    if (!s.length) return NaN;
    const h = s.length >> 1;
    return s.length % 2 ? s[h] : (s[h - 1] + s[h]) / 2;
  }
  function solve(A, b) {
    const n2 = A.length;
    const vec = !Array.isArray(b[0]);
    const M = A.map((row, i) => [...row, ...vec ? [b[i]] : b[i]]);
    for (let c = 0; c < n2; c++) {
      let p = c;
      for (let r = c + 1; r < n2; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
      if (Math.abs(M[p][c]) < 1e-300) throw new Error("singular matrix");
      [M[c], M[p]] = [M[p], M[c]];
      for (let r = c + 1; r < n2; r++) {
        const f = M[r][c] / M[c][c];
        if (f) for (let k = c; k < M[r].length; k++) M[r][k] -= f * M[c][k];
      }
    }
    const w = M[0].length - n2;
    const X = Array.from({ length: n2 }, () => new Array(w).fill(0));
    for (let i = n2 - 1; i >= 0; i--) {
      for (let j = 0; j < w; j++) {
        let s = M[i][n2 + j];
        for (let k = i + 1; k < n2; k++) s -= M[i][k] * X[k][j];
        X[i][j] = s / M[i][i];
      }
    }
    return vec ? X.map((r) => r[0]) : X;
  }
  function inv(A) {
    const n2 = A.length;
    return solve(A, A.map((_, i) => Array.from({ length: n2 }, (_2, j) => i === j ? 1 : 0)));
  }
  function lstsq(X, y) {
    const m = X.length, n2 = X[0].length;
    const R = X.map((r) => [...r]);
    const q = [...y];
    for (let k = 0; k < n2; k++) {
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
      for (let j = k; j < n2; j++) {
        let d3 = 0;
        for (let i = k; i < m; i++) d3 += v[i] * R[i][j];
        const f2 = 2 * d3 / vv;
        for (let i = k; i < m; i++) R[i][j] -= f2 * v[i];
      }
      let d = 0;
      for (let i = k; i < m; i++) d += v[i] * q[i];
      const f = 2 * d / vv;
      for (let i = k; i < m; i++) q[i] -= f * v[i];
    }
    const beta = new Array(n2).fill(0);
    for (let i = n2 - 1; i >= 0; i--) {
      let s = q[i];
      for (let k = i + 1; k < n2; k++) s -= R[i][k] * beta[k];
      if (Math.abs(R[i][i]) < 1e-12 * Math.max(1, ...R[0].map(Math.abs))) throw new Error("rank deficient");
      beta[i] = s / R[i][i];
    }
    return beta;
  }
  function rint(v) {
    const r = Math.round(v);
    return Math.abs(v % 1) === 0.5 && r % 2 !== 0 ? r - 1 : r;
  }
  function pyRound(x, d = 0) {
    return Number.isFinite(x) ? Number(fmtFixed(x, d)) : x;
  }
  function npRound(x, d = 0) {
    return Number.isFinite(x) ? rint(x * 10 ** d) / 10 ** d : x;
  }
  function fmtPercent(x, d = 0) {
    return fmtFixed(x * 100, d) + "%";
  }

  // src/tables.js
  var pad = (n2, w = 2) => String(n2).padStart(w, "0");
  var isoOf = (ms4) => {
    const d = new Date(ms4);
    return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
  };
  var msOf = (y, mo, d, h, mi, s) => Date.UTC(+y, +mo - 1, +d, +h, +mi, +s);
  function ts(s) {
    if (!s || s.length < 14) return null;
    return `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}T${s.slice(8, 10)}:${s.slice(10, 12)}:${s.slice(12, 14)}`;
  }
  var isoMs = (iso) => Date.parse(iso + "Z");
  var n = (v) => v ?? null;
  var add = (a, b) => a == null || b == null ? null : a + b;
  var keys = (files, re) => Object.keys(files).filter((k) => !k.endsWith(".meta.json") && re.test(k)).sort();
  function buildDays(files) {
    const rows = /* @__PURE__ */ new Map();
    for (const k of keys(files, /^raw\/days\/[^/]+\/[^/]+\.json$/)) {
      const vid = k.split("/")[2];
      for (const d of (files[k].resMsg || {}).dayTripList || []) {
        const day2 = `${d.tripDay.slice(0, 4)}-${d.tripDay.slice(4, 6)}-${d.tripDay.slice(6)}`;
        const key = `${vid}|${day2}`;
        rows.delete(key);
        rows.set(key, {
          vehicle_id: vid,
          day: day2,
          trip_count: n(d.dayTripCnt),
          distance_km: n(d.tripDist),
          drive_min: n(d.tripDrvTime),
          idle_min: n(d.tripIdleTime),
          avg_kmh: n(d.tripAvgSpeed),
          max_kmh: n(d.tripMaxSpeed)
        });
      }
    }
    return [...rows.values()];
  }
  function buildTrips(files) {
    const trips = /* @__PURE__ */ new Map();
    const points = [];
    for (const k of keys(files, /^raw\/trips\/[^/]+\/[^/]+\.json$/)) {
      const vid = k.split("/")[2];
      const t = (files[k].resMsg || {}).tripInfo;
      if (!t) continue;
      const pts = t.tripList || [];
      const hasRoute = pts.length > 1;
      const start = t.tripStartCoord || {}, end = t.tripEndCoord || {};
      const tripId = t.tripStartTime;
      const key = `${vid}|${tripId}`;
      trips.delete(key);
      trips.set(key, {
        vehicle_id: vid,
        trip_id: tripId,
        day: ts(tripId).slice(0, 10),
        start_ts: ts(tripId),
        end_ts: ts(t.tripEndTime),
        distance_km: n(t.tripDist),
        drive_min: n(t.tripDrvTime),
        idle_min: n(t.tripIdleTime),
        avg_kmh: n(t.tripAvgSpeed),
        max_kmh: n(t.tripMaxSpeed),
        hard_brake: n(t.tripHardBreakingTime),
        rapid_accel: n(t.tripRapidAccelationTime),
        overspeed: n(t.tripExcessiveSpeedTime),
        start_lat: hasRoute ? n(start.lat) : null,
        start_lon: hasRoute ? n(start.lon) : null,
        end_lat: hasRoute ? n(end.lat) : null,
        end_lon: hasRoute ? n(end.lon) : null,
        gps_points: pts.length,
        has_route: hasRoute ? 1 : 0
      });
      if (hasRoute) {
        let dayMs = msOf(tripId.slice(0, 4), tripId.slice(4, 6), tripId.slice(6, 8), 0, 0, 0);
        let prev = null;
        pts.forEach((p, i) => {
          const c = String(p.tripTime).padStart(6, "0");
          if (prev !== null && c < prev) dayMs += 864e5;
          prev = c;
          points.push({
            vehicle_id: vid,
            trip_id: tripId,
            seq: i,
            ts: isoOf(dayMs + (+c.slice(0, 2) * 3600 + +c.slice(2, 4) * 60 + +c.slice(4, 6)) * 1e3),
            lat: p.lat,
            lon: p.lon
          });
        });
      }
    }
    return { trips: [...trips.values()], points };
  }
  function buildSnapshots(files) {
    const dirs = /* @__PURE__ */ new Map();
    for (const k of keys(files, /^raw\/snapshots\/[^/]+\/[^/]+\/[^/]+\.json$/)) {
      const [, , vid, stamp] = k.split("/");
      dirs.set(`${vid}/${stamp}`, { vid, stamp });
    }
    const rows = [];
    for (const [dir, { vid, stamp }] of dirs) {
      const part = (name) => files[`raw/snapshots/${dir}/${name}.json`]?.resMsg || {};
      const status = part("status_latest"), loc = part("location_park"), maint = part("maintenance_alert");
      const coord = loc.coord || {};
      const hasStatus = Object.keys(status).length > 0;
      rows.push({
        vehicle_id: vid,
        taken_at: `${stamp.slice(0, 4)}-${stamp.slice(4, 6)}-${stamp.slice(6, 8)}T${stamp.slice(9, 11)}:${stamp.slice(11, 13)}:${stamp.slice(13, 15)}`,
        status_time: ts(status.time),
        odometer_km: n(maint.odometer),
        fuel_pct: n(status.fuelLevel),
        range_km: n(status.dte?.value),
        low_fuel: hasStatus ? +Boolean(status.lowFuelLight) : null,
        door_lock: hasStatus ? +Boolean(status.doorLock) : null,
        engine_on: hasStatus ? +Boolean(status.engine) : null,
        battery_state: n(status.battery?.batState),
        park_lat: n(coord.lat),
        park_lon: n(coord.lon),
        park_time: ts(loc.time)
      });
    }
    return rows;
  }
  var byKey = (f) => (a, b) => f(a) < f(b) ? -1 : f(a) > f(b) ? 1 : 0;
  function breadcrumbTimes(points) {
    const p = [...points].sort((a, b) => a.trip_id < b.trip_id ? -1 : a.trip_id > b.trip_id ? 1 : a.seq - b.seq);
    const groups = /* @__PURE__ */ new Map();
    const lastOfTrip = /* @__PURE__ */ new Map();
    for (const r of p) {
      const g = `${r.trip_id}|${r.ts}`;
      if (!groups.has(g)) {
        const grp = { size: 0, nextTs: null };
        groups.set(g, grp);
        const prevGrp = lastOfTrip.get(r.trip_id);
        if (prevGrp) prevGrp.grp.nextTs = r.ts;
        lastOfTrip.set(r.trip_id, { grp });
      }
      groups.get(g).size++;
    }
    const seen = /* @__PURE__ */ new Map();
    return p.map((r) => {
      const g = `${r.trip_id}|${r.ts}`;
      const grp = groups.get(g);
      const k = seen.get(g) ?? 0;
      seen.set(g, k + 1);
      const tsSec = isoMs(r.ts) / 1e3;
      const gap = grp.nextTs == null ? 60 : Math.max(1, isoMs(grp.nextTs) / 1e3 - tsSec);
      const offNs = Math.round(k / grp.size * gap * 1e9);
      return { r, tsSec, offNs };
    });
  }
  function pointsWithSpeed(points) {
    const rows = breadcrumbTimes(points);
    const out = [];
    let i = 0;
    while (i < rows.length) {
      let j = i;
      while (j < rows.length && rows[j].r.trip_id === rows[i].r.trip_id) j++;
      const raw = [];
      for (let a = i; a < j; a++) {
        if (a === i) {
          raw.push(0);
          continue;
        }
        const q = rows[a - 1], c = rows[a];
        const dKm = haversineKm(q.r.lat, q.r.lon, c.r.lat, c.r.lon);
        const dH = (c.tsSec - q.tsSec + (c.offNs - q.offNs) / 1e9) / 3600;
        raw.push(dH > 0 ? Math.min(dKm / dH, 160) : 0);
      }
      for (let a = 0; a < raw.length; a++) {
        const { r, tsSec, offNs } = rows[i + a];
        const tMs = Math.floor(tsSec * 1e3 + offNs / 1e6);
        out.push({
          ...r,
          t: `${isoOf(tMs)}.${pad((tMs % 1e3 + 1e3) % 1e3, 3)}`,
          speed: median(raw.slice(Math.max(0, a - 2), a + 3))
        });
      }
      i = j;
    }
    return out;
  }
  function loadTables(files) {
    const { trips, points } = buildTrips(files);
    for (const t of trips) {
      t.date = t.start_ts.slice(0, 10);
      t.total_min = add(t.drive_min, t.idle_min);
      t.elapsed_min = t.end_ts == null ? null : (isoMs(t.end_ts) - isoMs(t.start_ts)) / 6e4;
    }
    return {
      trips: trips.sort(byKey((r) => r.start_ts)),
      points: pointsWithSpeed(points),
      snaps: buildSnapshots(files).sort(byKey((r) => r.taken_at)),
      days: buildDays(files)
    };
  }
  function latestRaw(files, name) {
    const re = new RegExp(`^raw/snapshots/[^/]+/[^/]+/${name}\\.json$`);
    const ks = Object.keys(files).filter((k) => re.test(k)).sort();
    return ks.length ? files[ks[ks.length - 1]].resMsg || {} : {};
  }

  // src/logs.js
  var PREMIUM_MARKUP = 1.08;
  var num = (v) => v == null || Number.isNaN(v) ? null : v;
  var day = (iso) => Date.parse(iso.slice(0, 10) + "T00:00:00Z");
  function readable(entries, warn) {
    return entries.filter((e) => {
      if (e === null || typeof e !== "object" || typeof e.date !== "string" || !/^\d{4}-\d{2}-\d{2}/.test(e.date)) {
        warn(`skipping entry ${e && e.id ? e.id : "?"}: missing or invalid date`);
        return false;
      }
      if ((e.schema ?? 1) > 1) {
        warn(`skipping entry ${e.id ?? "?"}: unsupported schema ${e.schema}`);
        return false;
      }
      return true;
    });
  }
  var byDate = (a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : 0;
  var sortedByDate = (xs) => [...xs].sort(byDate);
  function fillsFromRefuels(entries, warn = console.warn) {
    const f = readable(entries, warn).map((e) => ({
      id: e.id ?? null,
      entered_at: e.entered_at ?? null,
      date: e.date.slice(0, 10) + "T00:00:00",
      amount: num(e.amount),
      litres: num(e.litres),
      logged_km: num(e.odometer_km),
      rate: num(e.rate),
      station: String(e.station ?? "").trim().replace(/\s+/g, " "),
      brand: (e.company ?? "").trim() || "Unknown",
      imputed: "",
      full_tank: e.full_tank ?? null,
      missed: !!e.missed,
      time: e.time ?? null
    }));
    const needRate = f.map((r) => r.rate === null && r.litres !== null && r.amount !== null);
    f.forEach((r, i) => {
      if (needRate[i]) {
        r.rate = r.amount / r.litres;
        r.imputed = "rate";
      }
    });
    const needL = f.map((r) => r.litres === null && r.amount !== null);
    f.forEach((r, i) => {
      if (!needL[i]) return;
      const withRate = f.filter((x) => x.rate !== null);
      const same = withRate.filter((x) => x.station === r.station);
      const pool = same.length ? same : withRate;
      if (!pool.length) return;
      let near = pool[0], best = Math.abs(day(pool[0].date) - day(r.date));
      for (const x of pool) {
        const d = Math.abs(day(x.date) - day(r.date));
        if (d < best) {
          best = d;
          near = x;
        }
      }
      r.rate = near.rate;
      r.litres = r.amount / r.rate;
      r.imputed = "litres";
    });
    for (const r of f) {
      if (r.amount === null && r.litres !== null && r.rate !== null) {
        r.amount = r.litres * r.rate;
        r.imputed = "amount";
      }
    }
    const out = sortedByDate(f);
    const cut = median(out.map((r) => r.rate)) * PREMIUM_MARKUP;
    for (const r of out) r.premium = r.rate !== null && r.rate > cut;
    return out.map(({ id, entered_at, date, amount, litres, logged_km, rate, station, brand, imputed, premium, full_tank, missed, time }) => ({ id, entered_at, date, amount, litres, logged_km, rate, station, brand, imputed, premium, full_tank, missed, time }));
  }
  function servicesFrom(entries, warn = console.warn) {
    return sortedByDate(readable(entries, warn)).map((e) => ({
      id: e.id,
      entered_at: e.entered_at,
      date: e.date,
      odometer_km: e.odometer_km,
      kind: e.kind,
      workshop: e.workshop,
      invoice: e.invoice,
      parts: (e.parts ?? []).map((p) => ({ ...p, resets: p.resets ?? [] })),
      labour: e.labour ?? [],
      parts_total: e.parts_total,
      gst: e.gst,
      total: e.total,
      notes: e.notes,
      photos: e.photos ?? []
    }));
  }
  function maintenanceFrom(entries, warn = console.warn) {
    return sortedByDate(readable(entries, warn)).map((e) => ({ ...e }));
  }

  // src/fuel.js
  var TANK_L = 37;
  var ARAI_KMPL = 20.35;
  var BRIM_L = 30;
  var PREMIUM_MARKUP2 = 1.08;
  var HWY_KMH = 50;
  var PRIOR = { city_l100: [7.5, 2.5], hwy_l100: [5.5, 1.5], idle_lph: [0.75, 0.25] };
  var NAMES = Object.keys(PRIOR);
  var DAY = 864e5;
  var MIN = 6e4;
  var pad2 = (n2) => String(n2).padStart(2, "0");
  var ms = (iso) => Date.parse(iso + "Z");
  var isoOf2 = (t) => {
    const d = new Date(t);
    return `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}T${pad2(d.getUTCHours())}:${pad2(d.getUTCMinutes())}:${pad2(d.getUTCSeconds())}`;
  };
  var dayOf = (t) => Math.floor(t / DAY) * DAY;
  var isNum = (v) => v != null && !Number.isNaN(v);
  var rnd = (x, d = 0) => isNum(x) ? Number(fmtFixed(x, d)) : null;
  var rint2 = (v) => {
    const r = Math.round(v);
    return Math.abs(v % 1) === 0.5 ? 2 * Math.round(v / 2) : r;
  };
  var npr = (x, d) => isNum(x) ? rint2(x * 10 ** d) / 10 ** d : null;
  var sum = (xs) => {
    let s = 0;
    for (const v of xs) if (isNum(v)) s += v;
    return s;
  };
  var linspace = (a, b, n2) => Array.from({ length: n2 }, (_, i) => i === n2 - 1 ? b : a + i * (b - a) / (n2 - 1));
  function indexTrips(trips) {
    const T = trips.map((t) => ({ ...t, s: ms(t.start_ts), e: t.end_ts ? ms(t.end_ts) : ms(t.start_ts) }));
    const n2 = T.length;
    const sufKm = new Array(n2 + 1).fill(0);
    for (let i = n2 - 1; i >= 0; i--) sufKm[i] = sufKm[i + 1] + (T[i].distance_km ?? 0);
    const byDay = /* @__PURE__ */ new Map();
    T.forEach((t, i) => {
      const d = dayOf(t.s);
      if (!byDay.has(d)) byDay.set(d, []);
      byDay.get(d).push(i);
    });
    const firstAt = (moment) => {
      let lo = 0, hi = n2;
      while (lo < hi) {
        const m = lo + hi >> 1;
        if (T[m].s >= moment) hi = m;
        else lo = m + 1;
      }
      return lo;
    };
    const candidates = (day2) => {
      const ix = byDay.get(day2);
      if (!ix) return [day2 + 12 * 60 * MIN];
      return [...ix.map((i) => T[i].s), T[ix[ix.length - 1]].e + MIN];
    };
    const odoAt = (moment, odoNow, delta) => {
      const k = firstAt(moment), cnt = n2 - k;
      return { odo: odoNow - sufKm[k] - delta * cnt, n: cnt, s: sufKm[k] };
    };
    const best = (day2, logged, odoNow, delta) => {
      let bm = null, bd = Infinity;
      for (const c of candidates(day2)) {
        const d = Math.abs(odoAt(c, odoNow, delta).odo - logged);
        if (d < bd) {
          bd = d;
          bm = c;
        }
      }
      return bm;
    };
    return { T, firstDay: dayOf(T[0].s), firstAt, candidates, odoAt, best };
  }
  var hasOdo = (f) => !f.missed && f.logged_km != null;
  var isBrim = (f) => f.full_tank ?? (isNum(f.litres) && f.litres >= BRIM_L);
  function calibrate(ix, fills, odoNow) {
    const logged = fills.map((f, i) => [f, i]).filter(([f]) => hasOdo(f) && ms(f.date) >= ix.firstDay);
    let delta = 0, rows = [], gap = [];
    for (let it = 0; it < 20; it++) {
      rows = logged.map(([f, i]) => {
        const m = ix.best(ms(f.date), f.logged_km, odoNow, delta);
        const { n: n2, s } = ix.odoAt(m, odoNow, delta);
        return { i, n: n2, s, gap: odoNow - s - f.logged_km };
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
      const mean3 = sum(resid) / resid.length;
      sd = Math.sqrt(sum(resid.map((v) => (v - mean3) ** 2)) / (resid.length - 1));
    }
    const points = rows.map((r, k) => ({
      date: fills[r.i].date.slice(0, 10),
      logged_km: fills[r.i].logged_km,
      rebuilt_raw: odoNow - r.s,
      rebuilt: odoNow - r.s - delta * r.n,
      resid: resid[k],
      trips_after: r.n
    }));
    return { delta, n: rows.length, resid_sd: sd, points };
  }
  function placeFills(ix, fills, odoNow, delta) {
    return fills.map((f) => {
      const out = { ...f, brim: isBrim(f), over_tank: isNum(f.litres) && f.litres > TANK_L, moment: null, odo: null };
      const day2 = ms(f.date);
      if (day2 < ix.firstDay) return out;
      const cands = ix.candidates(day2);
      out.moment = hasOdo(f) ? ix.best(day2, f.logged_km, odoNow, delta) : cands[cands.length >> 1];
      out.odo = ix.odoAt(out.moment, odoNow, delta).odo;
      return out;
    });
  }
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
        from: f[a].date.slice(0, 10),
        to: f[b].date.slice(0, 10),
        km,
        litres,
        kmpl: litres ? km / litres : null,
        city_km: sum(adj.filter((_, j) => !hwy[j])),
        hwy_km: sum(adj.filter((_, j) => hwy[j])),
        idle_h: sum(seg.map((t) => t.idle_min)) / 60,
        trips: seg.length,
        fills: b - a,
        avg_moving_kmh: drive ? sum(adj) / (drive / 60) : null,
        unknown
      });
    }
    for (const r of rows) {
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
  function cholesky(A) {
    const n2 = A.length;
    const L = Array.from({ length: n2 }, () => new Array(n2).fill(0));
    for (let i = 0; i < n2; i++) {
      for (let j = 0; j <= i; j++) {
        let s = A[i][j];
        for (let k = 0; k < j; k++) s -= L[i][k] * L[j][k];
        if (i === j) {
          if (s <= 0) throw new Error("matrix not positive definite");
          L[i][i] = Math.sqrt(s);
        } else L[i][j] = s / L[j][j];
      }
    }
    return L;
  }
  function cholSolve(L, b) {
    const n2 = L.length, z = new Array(n2), x = new Array(n2);
    for (let i = 0; i < n2; i++) {
      let s = b[i];
      for (let k = 0; k < i; k++) s -= L[i][k] * z[k];
      z[i] = s / L[i][i];
    }
    for (let i = n2 - 1; i >= 0; i--) {
      let s = z[i];
      for (let k = i + 1; k < n2; k++) s -= L[k][i] * x[k];
      x[i] = s / L[i][i];
    }
    return x;
  }
  function fitModel(iv) {
    const ok2 = iv.filter((r) => r.status === "ok");
    const X = ok2.map((r) => [r.city_km / 100, r.hwy_km / 100, r.idle_h]);
    const y = ok2.map((r) => r.litres);
    const N = y.length;
    const m0 = NAMES.map((k) => PRIOR[k][0]), s0 = NAMES.map((k) => PRIOR[k][1]);
    const P0d = s0.map((s) => 1 / s ** 2);
    const posterior = (sigma2, Xs, ys) => {
      const Pn = [0, 1, 2].map((i) => [0, 1, 2].map((j) => (i === j ? P0d[i] : 0) + Xs.reduce((a, r) => a + r[i] * r[j], 0) / sigma2 ** 2));
      const Sn2 = inv(Pn);
      const rhs = [0, 1, 2].map((i) => P0d[i] * m0[i] + Xs.reduce((a, r, k) => a + r[i] * ys[k], 0) / sigma2 ** 2);
      return { mn: Sn2.map((row) => row.reduce((a, v, j) => a + v * rhs[j], 0)), Sn: Sn2 };
    };
    const logEvidence = (sigma2) => {
      const C = X.map((xi, i) => X.map((xj, j) => xi.reduce((a, v, k) => a + v * s0[k] ** 2 * xj[k], 0) + (i === j ? sigma2 ** 2 : 0)));
      const r = y.map((v, i) => v - X[i].reduce((a, x, k) => a + x * m0[k], 0));
      const L = cholesky(C);
      const logdet = 2 * L.reduce((a, row, i) => a + Math.log(row[i]), 0);
      const w = cholSolve(L, r);
      return -0.5 * (r.reduce((a, v, i) => a + v * w[i], 0) + logdet + N * Math.log(2 * Math.PI));
    };
    const grid = linspace(1, 12, 111);
    const ev = grid.map(logEvidence);
    let best = 0;
    ev.forEach((v, i) => {
      if (v > ev[best]) best = i;
    });
    const sigma = grid[best];
    const { mn, Sn } = posterior(sigma, X, y);
    const sd = [0, 1, 2].map((i) => Math.sqrt(Sn[i][i]));
    const pred = X.map((xi) => xi.reduce((a, v, k) => a + v * mn[k], 0));
    const loo = [], naive = [];
    const kmAll = ok2.map((r) => r.km);
    for (let i = 0; i < N && N >= 2; i++) {
      const keep = y.map((_, k) => k !== i);
      const { mn: mk } = posterior(sigma, X.filter((_, k) => keep[k]), y.filter((_, k) => keep[k]));
      loo.push(y[i] - X[i].reduce((a, v, k) => a + v * mk[k], 0));
      const kmplK = sum(kmAll.filter((_, k) => keep[k])) / sum(y.filter((_, k) => keep[k]));
      naive.push(y[i] - kmAll[i] / kmplK);
    }
    const pdf = (x, m, s) => Math.exp(-0.5 * ((x - m) / s) ** 2) / (s * Math.sqrt(2 * Math.PI));
    const curves = {};
    NAMES.forEach((n2, j) => {
      const lo = Math.min(m0[j] - 3.5 * s0[j], mn[j] - 4 * sd[j]);
      const hi = Math.max(m0[j] + 3.5 * s0[j], mn[j] + 4 * sd[j]);
      const xs = linspace(Math.max(lo, 0), hi, 120);
      curves[n2] = {
        x: xs.map((v) => npr(v, 4)),
        prior: xs.map((v) => npr(pdf(v, m0[j], s0[j]), 5)),
        posterior: xs.map((v) => npr(pdf(v, mn[j], sd[j]), 5))
      };
    });
    const ybar = sum(y) / N;
    const obj = (arr) => Object.fromEntries(NAMES.map((n2, j) => [n2, arr[j]]));
    return {
      coef: obj(mn.map((v) => npr(v, 4))),
      sd: obj(sd.map((v) => npr(v, 4))),
      prior: Object.fromEntries(NAMES.map((k) => [k, { mean: PRIOR[k][0], sd: PRIOR[k][1] }])),
      posterior_corr: Sn.map((row, i) => row.map((v, j) => npr(v / (sd[i] * sd[j]), 3))),
      sigma_l: sigma,
      evidence: { sigma: grid.map((v) => npr(v, 2)), log_evidence: ev.map((v) => npr(v, 3)) },
      n_intervals: N,
      r2: N < 2 ? null : 1 - sum(y.map((v, i) => (v - pred[i]) ** 2)) / sum(y.map((v) => (v - ybar) ** 2)),
      loo_mae: N < 2 ? null : sum(loo.map(Math.abs)) / N,
      naive_loo_mae: N < 2 ? null : sum(naive.map(Math.abs)) / N,
      kmpl_city: 100 / mn[0],
      kmpl_hwy: 100 / mn[1],
      curves,
      fitted: ok2.map((r, i) => ({ from: r.from, to: r.to, actual: y[i], pred: pred[i] }))
    };
  }
  function tripCosts(ix, f, model, delta) {
    const c = model.coef;
    const rates = f.filter((r) => isNum(r.rate)).map((r) => [ms(r.date), r.rate]).sort((a, b) => a[0] - b[0]);
    return ix.T.map((t) => {
      const km_adj = t.distance_km + delta;
      const hwy = t.avg_kmh >= HWY_KMH;
      const move_l = (hwy ? c.hwy_l100 : c.city_l100) * km_adj / 100;
      const idle_l = c.idle_lph * t.idle_min / 60;
      const est_l = move_l + idle_l;
      let rate = rates.length ? rates[0][1] : null;
      for (const [d, r] of rates) {
        if (d <= t.s) rate = r;
        else break;
      }
      return {
        ...t,
        km_adj,
        hwy,
        move_l,
        idle_l,
        est_l,
        rate,
        est_cost: rate == null ? NaN : est_l * rate,
        idle_cost: rate == null ? NaN : idle_l * rate,
        kmpl_est: est_l > 0 ? km_adj / est_l : null
      };
    });
  }
  function tankLevel(t, f, iv, model, snaps) {
    const sd = NAMES.map((k) => model.sd[k]);
    const cov = model.posterior_corr.map((row, i) => row.map((v, j) => v * sd[i] * sd[j]));
    const placed = f.filter((r) => r.moment != null);
    const momentsOn = (date) => placed.filter((r) => r.date.slice(0, 10) === date).map((r) => r.moment);
    const blank = iv.filter((r) => r.status === "missing_fill").map((r) => [Math.min(...momentsOn(r.from)), Math.max(...momentsOn(r.to))]);
    const events = [
      ...placed.map((r) => ({ ts: r.moment, kind: 0, r })),
      ...t.map((r) => ({ ts: r.e, kind: 1, r }))
    ].sort((a, b) => a.ts - b.ts || a.kind - b.kind);
    const brimTimes = placed.filter((r) => r.brim).map((r) => r.moment);
    const endTs = events.length ? events[events.length - 1].ts + 1e3 : 0;
    for (const r of placed) {
      if (r.brim || isNum(r.litres)) continue;
      blank.push([r.moment, Math.min(endTs, ...brimTimes.filter((b) => b > r.moment))]);
    }
    let level = null, x = [0, 0, 0];
    const pts = [];
    const emit = (ts2) => {
      const gap = level === null || blank.some(([a, b]) => a <= ts2 && ts2 < b);
      const band = Math.sqrt(x.reduce((s, xi, i) => s + xi * cov[i].reduce((a, v, j) => a + v * x[j], 0), 0));
      pts.push([ts2, isoOf2(ts2), gap ? null : rnd(level, 2), gap ? null : rnd(band, 2)]);
    };
    for (const { ts: ts2, kind, r } of events) {
      if (kind === 0) {
        if (level !== null) emit(ts2);
        if (r.brim) {
          level = TANK_L;
          x = [0, 0, 0];
        } else if (level !== null && isNum(r.litres)) level = Math.min(level + r.litres, TANK_L);
        if (level !== null) emit(ts2);
      } else if (level !== null) {
        x = [x[0] + (r.hwy ? 0 : r.km_adj / 100), x[1] + (r.hwy ? r.km_adj / 100 : 0), x[2] + r.idle_min / 60];
        level = Math.max(level - r.est_l, 0);
        emit(ts2);
      }
    }
    const gauge = [];
    for (const s of snaps.filter((r) => isNum(r.fuel_pct))) {
      const when = s.status_time ?? s.taken_at;
      const w = ms(when);
      let before = null;
      for (const p of pts) {
        if (p[0] <= w) before = p;
        else break;
      }
      gauge.push([when, s.fuel_pct, s.range_km, before === null || before[2] === null ? null : rnd(before[2] / TANK_L * 100, 1)]);
    }
    return {
      points: pts.map((p) => p.slice(1)),
      gauge: gauge.filter((g, i) => i === 0 || g[0] !== gauge[i - 1][0]),
      // one per car report
      fills: placed.map((r) => [isoOf2(r.moment), rnd(r.litres, 2), r.brim]),
      gaps: blank.map(([a, b]) => [isoOf2(a), isoOf2(b)])
    };
  }
  var median45 = (regular, d0) => median(regular.filter((r) => Math.abs(ms(r.date) - d0) <= 45 * DAY).map((r) => r.rate));
  function nanToNull(v) {
    if (typeof v === "number") return Number.isFinite(v) ? v : null;
    if (Array.isArray(v)) return v.map(nanToNull);
    if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, nanToNull(x)]));
    return v;
  }
  function buildFuel(tables, fills, odoNow, { source = "refuel log" } = {}) {
    const { trips, snaps } = tables;
    if (!fills.length || !trips.length) return null;
    const ix = indexTrips(trips);
    odoNow = odoNow ?? sum(trips.map((t2) => t2.distance_km));
    const cal = calibrate(ix, fills, odoNow);
    const delta = cal.delta;
    const f = placeFills(ix, fills, odoNow, delta);
    const iv = intervals(ix, f, delta);
    if (!iv.some((r) => r.status === "ok")) return null;
    const model = fitModel(iv);
    const t = tripCosts(ix, f, model, delta);
    const c = model.coef;
    const missing = iv.filter((r) => r.status === "missing_fill").map((r) => {
      const need = r.city_km / 100 * c.city_l100 + r.hwy_km / 100 * c.hwy_l100 + r.idle_h * c.idle_lph;
      return { from: r.from, to: r.to, km: r.km, logged_l: r.litres, needed_l: need, unlogged_l: need - r.litres };
    });
    const valid = iv.filter((r) => r.status === "ok");
    const odos = f.map((r) => r.odo).filter(isNum);
    const premium = f.filter((r) => r.premium), regular = f.filter((r) => !r.premium);
    const premExtra = premium.length ? sum(premium.map((r) => (r.litres ?? 0) * (r.rate - median45(regular, ms(r.date))))) : 0;
    const cityT = t.filter((r) => !r.hwy);
    const kmAll = sum(t.map((r) => r.km_adj)), estL = sum(t.map((r) => r.est_l)), idleL = sum(t.map((r) => r.idle_l));
    const totals = {
      fills: f.length,
      litres: sum(f.map((r) => r.litres)),
      spend: sum(f.map((r) => r.amount)),
      avg_rate: sum(f.map((r) => r.amount)) / sum(f.map((r) => r.litres)),
      kmpl_valid: sum(valid.map((r) => r.km)) / sum(valid.map((r) => r.litres)),
      km_valid: sum(valid.map((r) => r.km)),
      rs_per_km_model: sum(t.map((r) => r.est_cost)) / kmAll,
      idle_l: idleL,
      idle_cost: sum(t.map((r) => r.idle_cost)),
      idle_share_of_fuel: idleL / estL,
      est_l_total: estL,
      est_cost_total: sum(t.map((r) => r.est_cost)),
      city_share_km: sum(cityT.map((r) => r.km_adj)) / kmAll,
      city_share_fuel: (sum(cityT.map((r) => r.move_l)) + sum(cityT.map((r) => r.idle_l))) / estL,
      premium_fills: premium.length,
      premium_extra: premExtra,
      missing_fills: missing.length,
      unlogged_l: sum(missing.map((m) => m.unlogged_l)),
      over_tank: f.filter((r) => r.over_tank).length,
      first_fill: f[0].date.slice(0, 10),
      last_fill: f.at(-1).date.slice(0, 10),
      odo_span: [odos[0], odos.at(-1)]
    };
    const months = /* @__PURE__ */ new Map();
    const slot = (m) => {
      if (!months.has(m)) months.set(m, { km: 0, est_l: 0, est_cost: 0, idle_cost: 0, spend: 0, litres: 0 });
      return months.get(m);
    };
    for (const r of t) {
      const s = slot(r.start_ts.slice(0, 7));
      s.km += r.km_adj;
      s.est_l += r.est_l;
      s.est_cost += r.est_cost;
      s.idle_cost += r.idle_cost;
    }
    for (const r of f) {
      const s = slot(r.date.slice(0, 7));
      s.spend += r.amount ?? 0;
      s.litres += r.litres ?? 0;
    }
    const brands = [...groupBy(f, (r) => r.brand)].sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0).map(([brand, rs]) => ({
      brand,
      fills: rs.length,
      litres: sum(rs.map((r) => r.litres)),
      spend: sum(rs.map((r) => r.amount)),
      rate: median(rs.map((r) => r.rate))
    })).sort((a, b) => b.litres - a.litres).map((b) => ({ ...b, litres: npr(b.litres, 2), spend: npr(b.spend, 2), rate: npr(b.rate, 2) }));
    const ivOut = iv.map(({ unknown, ...r }) => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, typeof v === "number" && k !== "trips" && k !== "fills" ? npr(v, 3) : v])));
    return nanToNull({
      source,
      constants: { tank_l: TANK_L, arai_kmpl: ARAI_KMPL, brim_l: BRIM_L, hwy_kmh: HWY_KMH, premium_markup: PREMIUM_MARKUP2 },
      calibration: cal,
      fills: f.map((r) => ({
        date: r.date.slice(0, 10),
        moment: r.moment == null ? null : isoOf2(r.moment),
        station: r.station,
        brand: r.brand,
        litres: rnd(r.litres, 2),
        amount: rnd(r.amount, 2),
        rate: rnd(r.rate, 2),
        premium: !!r.premium,
        imputed: r.imputed || null,
        logged_km: r.logged_km,
        odo: rnd(r.odo, 1),
        brim: r.brim,
        over_tank: r.over_tank
      })),
      intervals: ivOut,
      model,
      missing,
      totals,
      monthly: [...months].sort((a, b) => a[0] < b[0] ? -1 : 1).map(([month, s]) => ({
        month,
        km: rnd(s.km, 1),
        est_l: rnd(s.est_l, 2),
        est_cost: rnd(s.est_cost),
        idle_cost: rnd(s.idle_cost),
        spend: rnd(s.spend),
        litres: rnd(s.litres, 2)
      })),
      brands,
      trips: t.map((r) => ({
        id: r.trip_id,
        start: r.start_ts,
        km: rnd(r.km_adj, 2),
        est_l: rnd(r.est_l, 3),
        idle_l: rnd(r.idle_l, 3),
        cost: rnd(r.est_cost, 1),
        kmpl: rnd(r.kmpl_est, 2),
        hwy: r.hwy,
        avg: r.avg_kmh,
        idle_share: r.drive_min + r.idle_min ? rnd(r.idle_min / (r.drive_min + r.idle_min), 3) : 0
      })),
      fuel_level: snaps.filter((r) => isNum(r.fuel_pct)).map((r) => [r.taken_at, r.fuel_pct, r.range_km]),
      tank: tankLevel(t, f, iv, model, snaps)
    });
  }

  // src/insights.js
  var TANK_L2 = 37;
  var CELL = 15e-4;
  var SLOW_KMH = 8;
  var WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
  var DAY2 = 864e5;
  var isNum2 = (v) => v != null && !Number.isNaN(v);
  var sum2 = (xs) => {
    let s = 0;
    for (const v of xs) if (isNum2(v)) s += v;
    return s;
  };
  var ms2 = (iso) => Date.parse(iso.length === 10 ? iso + "T00:00:00Z" : iso + "Z");
  var pad3 = (n2) => String(n2).padStart(2, "0");
  var isoDay = (t) => {
    const d = new Date(t);
    return `${d.getUTCFullYear()}-${pad3(d.getUTCMonth() + 1)}-${pad3(d.getUTCDate())}`;
  };
  var addDays = (iso, n2) => isoDay(ms2(iso.slice(0, 10)) + n2 * DAY2);
  var daysBetween = (a, b) => Math.round((ms2(a.slice(0, 10)) - ms2(b.slice(0, 10))) / DAY2);
  var dow = (iso) => (new Date(ms2(iso)).getUTCDay() + 6) % 7;
  var hourOf = (iso) => +iso.slice(11, 13);
  var cmpStr = (a, b) => a < b ? -1 : a > b ? 1 : 0;
  var maxIdx = (xs) => xs.reduce((bi, v, i) => v > xs[bi] ? i : bi, 0);
  var minIdx = (xs) => xs.reduce((bi, v, i) => v < xs[bi] ? i : bi, 0);
  var mean = (xs) => sum2(xs) / xs.length;
  var cellOf = (lat, lon) => isNum2(lat) && isNum2(lon) ? `${rint(lat / CELL)}:${rint(lon / CELL)}` : "<NA>:<NA>";
  function mode(xs) {
    const c = /* @__PURE__ */ new Map();
    for (const x of xs) c.set(x, (c.get(x) ?? 0) + 1);
    let best = null;
    for (const [k, v] of c) if (best === null || v > c.get(best) || v === c.get(best) && k < best) best = k;
    return best;
  }
  function findPlaces(routed) {
    const ends = [
      ...routed.map((r) => ({ lat: r.start_lat, lon: r.start_lon, ts: r.start_ts, kind: "start" })),
      ...routed.map((r) => ({ lat: r.end_lat, lon: r.end_lon, ts: r.end_ts, kind: "end" }))
    ];
    for (const e of ends) e.cell = cellOf(e.lat, e.lon);
    const agg = [...groupBy(ends, (e) => e.cell)].sort((a, b) => cmpStr(a[0], b[0])).map(([cell, es]) => ({ cell, lat: mean(es.map((e) => e.lat)), lon: mean(es.map((e) => e.lon)), visits: es.length }));
    const lastOfDay = [...groupBy([...routed].sort((a, b) => cmpStr(a.end_ts, b.end_ts)), (r) => r.date)].map(([, rs]) => rs.at(-1));
    const home = mode(lastOfDay.map((r) => cellOf(r.end_lat, r.end_lon)));
    const wd = ends.filter((e) => e.kind === "end" && dow(e.ts) < 5 && hourOf(e.ts) >= 7 && hourOf(e.ts) <= 11 && e.cell !== home);
    const work = wd.length ? mode(wd.map((e) => e.cell)) : null;
    agg.sort((a, b) => b.visits - a.visits || cmpStr(b.cell, a.cell));
    let i = 1;
    const out = [];
    for (const a of agg) {
      let name = null;
      if (a.cell === home) name = "Home";
      else if (a.cell === work) name = "Work";
      else if (a.visits >= 6) name = `Place ${i++}`;
      if (name) out.push({ ...a, name });
    }
    return out;
  }
  function nearestPlace(lat, lon, places, withinKm = 0.35) {
    if (!isNum2(lat) || !places.length) return null;
    const d = places.map((p) => haversineKm(lat, lon, p.lat, p.lon));
    const i = minIdx(d);
    return d[i] <= withinKm ? places[i].name : null;
  }
  function clock(h, suffix = true) {
    const hh = Math.trunc(h), mm = pyRound(h % 1 * 60);
    return `${hh % 12 || 12}:${pad3(mm)}` + (suffix ? ` ${hh < 12 ? "am" : "pm"}` : "");
  }
  function halfHour(h) {
    const same = h < 12 === h + 0.5 < 12;
    return `${clock(h, !same)}\u2013${clock(h + 0.5)}`;
  }
  function commuteFinding(rows, direction) {
    if (rows.length < 8) return null;
    const slots = groupBy(rows, (r) => Math.floor((hourOf(r.start_ts) + +r.start_ts.slice(14, 16) / 60) * 2) / 2);
    const g = [...slots].filter(([, rs]) => rs.length >= 3).sort((a, b) => a[0] - b[0]).map(([slot, rs]) => ({ slot, med: median(rs.map((r) => r.elapsed_min)) }));
    if (g.length < 2) return null;
    const best = g[minIdx(g.map((x) => x.med))], worst = g[maxIdx(g.map((x) => x.med))];
    if (worst.med - best.med < 4) return `Your ${direction} takes about the same time whenever you leave.`;
    return `Leave at ${halfHour(best.slot)} and your ${direction} takes ${fmtFixed(best.med, 0)} min. At ${halfHour(worst.slot)}, it's ${fmtFixed(worst.med, 0)}.`;
  }
  function hotspots(points, routed, places) {
    if (!points.length) return [];
    const span = new Map(routed.map((r) => [r.trip_id, [ms2(r.start_ts), ms2(r.end_ts)]]));
    const slow = [];
    let prevTrip = null, prevT = null;
    for (const p of points) {
      const s = span.get(p.trip_id);
      if (!s) continue;
      const t = ms2(p.t);
      if (!(t > s[0] + 6e4 && t < s[1] - 6e4)) continue;
      const dt = p.trip_id === prevTrip ? Math.min((t - prevT) / 1e3, 30) : 0;
      prevTrip = p.trip_id;
      prevT = t;
      if (p.speed < SLOW_KMH) slow.push({ ...p, dt });
    }
    if (!slow.length) return [];
    const named = places.filter((p) => p.visits >= 3);
    const far = named.length ? slow.filter((p) => Math.min(...named.map((n2) => haversineKm(p.lat, p.lon, n2.lat, n2.lon))) > 0.25) : slow;
    const cells = groupBy(far, (p) => `${rint(p.lat / 2e-3)}:${rint(p.lon / 2e-3)}`);
    return [...cells].sort((a, b) => cmpStr(a[0], b[0])).map(([, ps]) => ({
      lat: mean(ps.map((p) => p.lat)),
      lon: mean(ps.map((p) => p.lon)),
      seconds: sum2(ps.map((p) => p.dt)),
      trips: new Set(ps.map((p) => p.trip_id)).size
    })).filter((c) => c.trips >= 3).sort((a, b) => b.seconds - a.seconds).slice(0, 8).map((c) => ({
      lat: pyRound(c.lat, 5),
      lon: pyRound(c.lon, 5),
      minutes: pyRound(c.seconds / 60),
      trips: c.trips,
      per_trip: npRound(c.seconds / 60 / c.trips, 1)
    }));
  }
  function addMonths(iso, months) {
    const y = +iso.slice(0, 4), m0 = +iso.slice(5, 7) - 1 + months, d = +iso.slice(8, 10);
    const yy = y + Math.floor(m0 / 12), mm = (m0 % 12 + 12) % 12;
    return `${yy}-${pad3(mm + 1)}-${pad3(Math.min(d, 28))}`;
  }
  function servicePlan(files, odo, reg, pace, today, services) {
    const rows = [];
    for (const item of latestRaw(files, "maintenance_alert").mainList ?? []) {
      const everyKm = item.items?.distValue || 0;
      const everyMo = item.items?.termValue || 0;
      if (!everyKm) continue;
      const done = services.filter((s) => (s.parts ?? []).some((p) => (p.resets ?? []).includes(item.itemId)));
      const last = done.at(-1) ?? null;
      let timeDate = null, kmDue;
      if (last) {
        kmDue = last.odometer_km + everyKm;
        if (everyMo) timeDate = addMonths(last.date, everyMo);
      } else {
        kmDue = (Math.floor(odo / everyKm) + 1) * everyKm;
        if (everyMo && reg) {
          let n2 = 1;
          while (addMonths(reg, everyMo * n2) <= today) n2++;
          timeDate = addMonths(reg, everyMo * n2);
        }
      }
      const kmDate = pace ? addDays(today, Math.floor((kmDue - odo) / pace)) : null;
      const byTime = timeDate !== null && (kmDate === null || timeDate < kmDate);
      const due = byTime ? timeDate : kmDate;
      rows.push({
        item: item.itemId,
        every_km: everyKm,
        every_months: everyMo,
        due,
        days_left: due ? daysBetween(due, today) : null,
        trigger: byTime ? "time" : "distance",
        km_due: kmDue,
        last_done: last ? { date: last.date, km: last.odometer_km } : null
      });
    }
    return rows.sort((a, b) => (a.days_left ?? 1e9) - (b.days_left ?? 1e9));
  }
  function runningCost(odo, fuel, services, maintenance) {
    const fuelRs = fuel?.totals?.est_cost_total ?? 0;
    const serviceRs = sum2(services.map((s) => s.total));
    const otherRs = sum2(maintenance.map((m) => m.cost));
    const per = (v) => odo ? v / odo : null;
    const fuelPer = fuel?.totals?.rs_per_km_model ?? (odo ? 0 : null);
    const total = fuelPer == null || !odo ? null : fuelPer + per(serviceRs) + per(otherRs);
    return {
      km: odo,
      fuel_rs: fuelRs,
      service_rs: serviceRs,
      other_rs: otherRs,
      per_km: { fuel: fuelPer, service: per(serviceRs), other: per(otherRs), total }
    };
  }
  function reminders(maintenance, today) {
    const from = addDays(today, -30);
    return maintenance.filter((m) => m.reminder && m.reminder.slice(0, 10) >= from).map((m) => ({ date: m.reminder.slice(0, 10), category: m.category, note: m.note ?? null, days_left: daysBetween(m.reminder, today) })).sort((a, b) => cmpStr(a.date, b.date));
  }
  function buildOverview(tables, files, { today, delta, fuel = null, services = [], maintenance = [] }) {
    const { trips, points, snaps } = tables;
    delta = delta ?? fuel?.calibration?.delta ?? 0;
    let routed = trips.filter((t) => t.has_route === 1);
    const places = routed.length ? findPlaces(routed) : [];
    for (const t of trips) {
      t.from_place = nearestPlace(t.start_lat, t.start_lon, places);
      t.to_place = nearestPlace(t.end_lat, t.end_lon, places);
    }
    routed = trips.filter((t) => t.has_route === 1);
    const vehicle = (latestRaw(files, "vehicles").vehicles ?? [{}])[0] ?? {};
    const reg = vehicle.regDate ? vehicle.regDate.slice(0, 10) : null;
    const last = snaps.length ? snaps.at(-1) : null;
    const odo = last && isNum2(last.odometer_km) ? last.odometer_km : sum2(trips.map((t) => t.distance_km));
    const cutoff = addDays(today, -90);
    const pace = sum2(trips.filter((t) => t.date > cutoff).map((t) => t.distance_km)) / 90;
    const km = sum2(trips.map((t) => t.distance_km)) + delta * trips.length;
    const totalMin = sum2(trips.map((t) => t.total_min)), idleMin = sum2(trips.map((t) => t.idle_min));
    const driveMin = sum2(trips.map((t) => t.drive_min));
    const idleShare = idleMin / totalMin;
    const wdOf = (t) => dow(t.start_ts), hrOf = (t) => hourOf(t.start_ts);
    const dates = trips.map((t) => t.date);
    const firstDay = dates.reduce((a, b) => b < a ? b : a), lastDay = dates.reduce((a, b) => b > a ? b : a);
    const weeks = Math.max(daysBetween(lastDay, firstDay) / 7, 1);
    const byWd = Array.from({ length: 7 }, (_, d) => sum2(trips.filter((t) => wdOf(t) === d).map((t) => t.distance_km)) / weeks);
    const rhythm = Array.from({ length: 7 }, () => new Array(24).fill(0));
    for (const t of trips) rhythm[wdOf(t)][hrOf(t)]++;
    const topWd = maxIdx(byWd);
    const weekdayAvg = mean(byWd.filter((_, d) => d !== topWd));
    const toWork = routed.filter((t) => t.from_place === "Home" && t.to_place === "Work");
    const toHome = routed.filter((t) => t.from_place === "Work" && t.to_place === "Home");
    const hrIdle = [...groupBy(trips, hrOf)].sort((a, b) => a[0] - b[0]).map(([h, ts2]) => ({ h, n: ts2.length, share: sum2(ts2.map((t) => t.idle_min)) / sum2(ts2.map((t) => t.total_min)) })).filter((r) => r.n >= 3);
    const worstHr = hrIdle.length ? hrIdle[maxIdx(hrIdle.map((r) => r.share))].h : null;
    const hs = hotspots(points, routed, places);
    const month = [...groupBy(trips, (t) => t.date.slice(0, 7))].sort((a, b) => cmpStr(a[0], b[0])).map(([m, ts2]) => ({
      m,
      km: sum2(ts2.map((t) => t.distance_km)),
      trips: ts2.length,
      drive: sum2(ts2.map((t) => t.drive_min))
    }));
    const bestMonth = month[maxIdx(month.map((r) => r.km))];
    const longest = trips[maxIdx(trips.map((t) => t.distance_km ?? -Infinity))];
    const shortShare = trips.filter((t) => t.distance_km < 3).length / trips.length;
    const events = sum2(trips.map((t) => (t.hard_brake ?? 0) + (t.rapid_accel ?? 0) + (t.overspeed ?? 0)));
    const findings = {
      hero: reg ? `Since ${fmtDate(reg, "%-d %B %Y")}, your i20 has covered ${fmtInt(odo)} km.` : `Your i20 has covered ${fmtInt(odo)} km.`,
      year: `${fmtDate(bestMonth.m + "-01", "%B")} was your biggest month at ${fmtInt(bestMonth.km)} km. Your longest drive was ${fmtFixed(longest.distance_km, 0)} km on ${fmtDate(longest.start_ts, "%-d %B")}.`,
      rhythm: `${WEEKDAYS[topWd]}s are your big days: ${fmtFixed(byWd[topWd], 0)} km on average, against ${fmtFixed(weekdayAvg, 0)} km on the other days.`,
      traffic: `You spend ${fmtPercent(idleShare)} of your time in the car standing still with the engine running: ${fmtFixed(idleMin / 60, 0)} hours so far` + (worstHr !== null ? `. It's worst on trips that start around ${clock(worstHr)}.` : "."),
      hotspots: hs.length >= 5 ? `You've lost ${fmtFixed(sum2(hs.slice(0, 5).map((h) => h.minutes)) / 60, 1)} hours crawling through these five spots.` : "Not enough routed trips to find hotspots yet.",
      commute_to_work: commuteFinding(toWork, "drive to work"),
      commute_to_home: commuteFinding(toHome, "drive home"),
      style: events ? `${events} flagged events in ${fmtInt(km)} km. That's one every ${fmtInt(km / events)} km.` : `Not one harsh brake, hard launch or speeding alert in ${fmtInt(km)} km.`,
      short: `${fmtPercent(shortShare)} of your trips are under 3 km. Those are the costliest kilometres you drive: a cold engine burns noticeably more fuel.`
    };
    const routes = {};
    for (const [tid, g] of groupBy(points, (p) => p.trip_id)) {
      const t0 = ms2(g[0].t);
      routes[tid] = g.map((p) => [pyRound(p.lat, 5), pyRound(p.lon, 5), pyRound(p.speed), Math.trunc((ms2(p.t) - t0) / 1e3)]);
    }
    const daily = [...groupBy(trips, (t) => t.date)].sort((a, b) => cmpStr(a[0], b[0])).map(([d, ts2]) => [d, sum2(ts2.map((t) => t.distance_km)), ts2.length]);
    const after = new Array(daily.length).fill(0);
    for (let i = daily.length - 2; i >= 0; i--) after[i] = after[i + 1] + daily[i + 1][1];
    const odoByDay = daily.map((_, i) => odo - after[i]);
    const milestones = [];
    for (let mark = 1e4; mark <= Math.trunc(odo); mark += 1e4) {
      const i = odoByDay.findIndex((o) => o >= mark);
      if (i >= 0) milestones.push({ km: mark, date: daily[i][0] });
    }
    const out = {
      generated_at: new Date(Date.now() + 198e5).toISOString().slice(0, 19),
      vehicle: { model: vehicle.vehicleName ?? "i20", reg_date: reg, year: vehicle.year ?? null },
      status: last === null ? null : {
        odometer: odo,
        fuel_pct: last.fuel_pct,
        fuel_l: isNum2(last.fuel_pct) ? rint(last.fuel_pct / 100 * TANK_L2) : null,
        range_km: last.range_km,
        locked: last.door_lock == null ? null : !!last.door_lock,
        low_fuel: last.low_fuel == null ? null : !!last.low_fuel,
        as_of: last.status_time ?? null,
        park: isNum2(last.park_lat) ? [last.park_lat, last.park_lon] : null
      },
      totals: {
        km,
        trips: trips.length,
        days_driven: new Set(dates).size,
        hours: totalMin / 60,
        idle_hours: idleMin / 60,
        idle_share: idleShare,
        moving_kmh: km / (driveMin / 60),
        top_kmh: Math.max(...trips.map((t) => t.max_kmh ?? -Infinity)),
        coverage: odo ? km / odo : null,
        pace_90d: pace,
        first_day: firstDay,
        last_day: lastDay,
        routed_trips: routed.length,
        short_share: shortShare,
        hard_brake: sum2(trips.map((t) => t.hard_brake)),
        rapid_accel: sum2(trips.map((t) => t.rapid_accel)),
        overspeed: sum2(trips.map((t) => t.overspeed))
      },
      findings,
      days: daily.map(([d, k, n2]) => [d, npRound(k, 1), n2]),
      months: month.map((r) => [r.m, pyRound(r.km), r.trips, r.drive ? pyRound(r.km / (r.drive / 60), 1) : 0]),
      rhythm,
      weekday_km: byWd.map((v) => pyRound(v, 1)),
      idle_by_hour: hrIdle.map((r) => [r.h, npRound(r.share, 3), r.n]),
      trips: trips.map((r) => ({
        id: r.trip_id,
        start: r.start_ts,
        end: r.end_ts,
        km: r.distance_km,
        drive: r.drive_min,
        idle: r.idle_min,
        avg: r.avg_kmh,
        max: r.max_kmh,
        events: [r.hard_brake ?? 0, r.rapid_accel ?? 0, r.overspeed ?? 0],
        route: !!r.has_route,
        from: r.from_place,
        to: r.to_place
      })),
      routes,
      places: places.slice(0, 12).map((p) => ({ name: p.name, lat: pyRound(p.lat, 5), lon: pyRound(p.lon, 5), visits: p.visits })),
      hotspots: hs,
      commute: Object.fromEntries([["to_work", toWork], ["to_home", toHome]].map(([k, rs]) => [k, rs.map((r) => ({ start: r.start_ts, min: pyRound(r.elapsed_min), km: r.distance_km }))])),
      service: servicePlan(files, odo, reg, pace, today, services),
      services,
      milestones,
      fuel: snaps.filter((s) => isNum2(s.fuel_pct)).map((s) => [s.taken_at, s.fuel_pct, s.range_km]),
      running_cost: runningCost(odo, fuel, services, maintenance),
      reminders: reminders(maintenance, today)
    };
    if (fuel) {
      out.tank = fuel.tank;
      out.fuel_rs_per_km = fuel.totals.rs_per_km_model;
    }
    return JSON.parse(JSON.stringify(out, (_, v) => typeof v === "number" && !Number.isFinite(v) ? null : v));
  }

  // src/performance.js
  var COLD_SOAK_H = 4;
  var STOP_KMH = 3;
  var MOVE_KMH = 10;
  var BANDS = [
    [0, 5, "Stopped"],
    [5, 20, "5\u201320"],
    [20, 40, "20\u201340"],
    [40, 60, "40\u201360"],
    [60, 80, "60\u201380"],
    [80, 100, "80\u2013100"],
    [100, 999, "100+"]
  ];
  var WLTC = [["Low", 18.9, 56.5], ["Medium", 39.5, 76.6], ["High", 56.7, 97.4], ["Extra high", 91.7, 131.3]];
  var K = 3;
  var CLUSTER_FEATURES = ["log_km", "overall_kmh", "idle_share", "max_kmh", "log_min"];
  var DAY3 = 864e5;
  var num2 = (v) => v == null ? NaN : v;
  var ok = (v) => v != null && !Number.isNaN(v);
  var sum3 = (xs) => xs.reduce((a, b) => a + b, 0);
  var mean2 = (xs) => sum3(xs) / xs.length;
  var variance = (xs, ddof = 0) => {
    const m = mean2(xs);
    return sum3(xs.map((x) => (x - m) ** 2)) / (xs.length - ddof);
  };
  var ms3 = (iso) => Date.parse(iso + "Z");
  var dayIso = (msv) => new Date(msv).toISOString().slice(0, 10);
  var dow2 = (msv) => (new Date(msv).getUTCDay() + 6) % 7;
  var hourFrac = (msv) => {
    const d = new Date(msv);
    return d.getUTCHours() + d.getUTCMinutes() / 60;
  };
  var nr = (xs, d) => xs.map((x) => npRound(x, d));
  var by = (xs, f) => [...xs].sort((a, b) => f(a) - f(b));
  var ascKeys = (m) => [...m.keys()].sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
  function tripFeatures(trips, delta) {
    const t = trips.map((r) => ({ ...r })).sort((a, b) => a.start_ts < b.start_ts ? -1 : a.start_ts > b.start_ts ? 1 : 0);
    let prevEnd = null;
    for (const r of t) {
      const s = ms3(r.start_ts), e = r.end_ts == null ? NaN : ms3(r.end_ts);
      r.km = r.distance_km + delta;
      r.elapsed_min = (e - s) / 6e4;
      r.engine_min = r.drive_min + r.idle_min;
      r.idle_share = r.engine_min > 0 ? r.idle_min / r.engine_min : 0;
      r.overall_kmh = r.km / (Math.max(r.elapsed_min, 1) / 60);
      r.soak_h = prevEnd == null ? NaN : (s - prevEnd) / 36e5;
      r.cold = Number.isNaN(r.soak_h) || r.soak_h >= COLD_SOAK_H;
      r.hour = hourFrac(s);
      r.wd = dow2(s);
      r.events = num2(r.hard_brake) + num2(r.rapid_accel) + num2(r.overspeed);
      r.log_km = Math.log1p(r.km);
      r.log_min = Math.log1p(r.elapsed_min);
      r.max_kmh = num2(r.max_kmh);
      r.avg_kmh = num2(r.avg_kmh);
      prevEnd = e;
    }
    return t;
  }
  var bandOf = (v) => BANDS.findIndex(([lo, hi]) => v >= lo && v < hi);
  function gpsFeatures(points) {
    const p = breadcrumbTimes(points).map(({ r, tsSec, offNs }) => ({ trip_id: r.trip_id, tm: (tsSec + offNs / 1e9) * 1e3, speed: r.speed }));
    p.sort((a, b) => a.trip_id < b.trip_id ? -1 : a.trip_id > b.trip_id ? 1 : a.tm - b.tm);
    let prev = null;
    for (const r of p) {
      if (prev && prev.trip_id === r.trip_id) {
        r.dt = Math.min((r.tm - prev.tm) / 1e3, 30);
        r.acc = r.dt > 0 ? Math.min(Math.max((r.speed / 3.6 - prev.speed / 3.6) / r.dt, -3), 3) : 0;
      } else {
        r.dt = 0;
        r.acc = 0;
      }
      r.band = bandOf(r.speed);
      prev = r;
    }
    const rows = [];
    for (const [tid, g] of groupBy(p, (r) => r.trip_id)) {
      const secs = sum3(g.map((r) => r.dt));
      if (secs <= 0) continue;
      const distM = sum3(g.map((r) => r.speed / 3.6 * r.dt));
      let moving = false, stops = 0;
      for (const { speed: s } of g) {
        if (s >= MOVE_KMH) moving = true;
        else if (s < STOP_KMH && moving) {
          stops++;
          moving = false;
        }
      }
      const rpa = distM > 50 ? sum3(g.map((r) => r.speed / 3.6 * Math.max(r.acc, 0) * r.dt)) / distM : NaN;
      const row = {
        trip_id: tid,
        rpa,
        stops,
        stops_per_km: distM > 200 ? stops / (distM / 1e3) : NaN,
        p95_kmh: quantile(g.map((r) => r.speed), 0.95),
        gps_secs: secs
      };
      BANDS.forEach(([, , name], i) => {
        row[`band_${name}`] = sum3(g.filter((r) => r.band === i).map((r) => r.dt)) / secs;
      });
      rows.push(row);
    }
    const vb = Array.from({ length: 15 }, (_, i) => i * 10);
    const ab = Array.from({ length: 13 }, (_, i) => npRound(-1.5 + i * 0.25, 2));
    const h = Array.from({ length: 14 }, () => new Array(12).fill(0));
    for (const r of p) {
      if (!(r.speed >= 2)) continue;
      const s = Math.min(Math.max(r.speed, 0), 139.9), a = Math.min(Math.max(r.acc, -1.499), 1.499);
      h[Math.floor(s / 10)][Math.floor((a + 1.5) / 0.25)] += r.dt;
    }
    const va = { speed_edges: vb, acc_edges: ab, seconds: h.map((row) => nr(row, 1)) };
    const tot = BANDS.map((_, i) => sum3(p.filter((r) => r.band === i).map((r) => r.dt)));
    const all = sum3(tot);
    const pooled = { bands: BANDS.map((b) => b[2]), share: nr(tot.map((v) => v / all), 4) };
    return { gf: rows, va, pooled };
  }
  function mulberry32(a) {
    return () => {
      a = a + 1831565813 | 0;
      let t = Math.imul(a ^ a >>> 15, 1 | a);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }
  var d2 = (a, b) => {
    let s = 0;
    for (let i = 0; i < a.length; i++) s += (a[i] - b[i]) ** 2;
    return s;
  };
  function kmeansOnce(X, k, rnd2) {
    const n2 = X.length, dim = X[0].length;
    const centers = [X[Math.floor(rnd2() * n2)].slice()];
    const near = X.map((x) => d2(x, centers[0]));
    while (centers.length < k) {
      const total = sum3(near);
      let r = rnd2() * total, i = 0;
      for (; i < n2 - 1; i++) {
        r -= near[i];
        if (r <= 0) break;
      }
      centers.push(X[i].slice());
      for (let j = 0; j < n2; j++) near[j] = Math.min(near[j], d2(X[j], centers[centers.length - 1]));
    }
    const labels = new Array(n2).fill(-1);
    for (let iter = 0; iter < 300; iter++) {
      let changed = false;
      for (let i = 0; i < n2; i++) {
        let best = 0, bd = Infinity;
        for (let c = 0; c < k; c++) {
          const d = d2(X[i], centers[c]);
          if (d < bd) {
            bd = d;
            best = c;
          }
        }
        if (labels[i] !== best) {
          labels[i] = best;
          changed = true;
        }
      }
      if (!changed) break;
      const cnt = new Array(k).fill(0), acc = Array.from({ length: k }, () => new Array(dim).fill(0));
      X.forEach((x, i) => {
        cnt[labels[i]]++;
        for (let j = 0; j < dim; j++) acc[labels[i]][j] += x[j];
      });
      for (let c = 0; c < k; c++) {
        if (cnt[c]) centers[c] = acc[c].map((v) => v / cnt[c]);
        else {
          let far = 0, fd = -1;
          X.forEach((x, i) => {
            const d = d2(x, centers[labels[i]]);
            if (d > fd) {
              fd = d;
              far = i;
            }
          });
          centers[c] = X[far].slice();
        }
      }
    }
    return { labels, inertia: sum3(X.map((x, i) => d2(x, centers[labels[i]]))) };
  }
  function kmeans(X, k, nInit, seed = 0) {
    const rnd2 = mulberry32(seed);
    let best = null;
    for (let i = 0; i < nInit; i++) {
      const r = kmeansOnce(X, k, rnd2);
      if (!best || r.inertia < best.inertia) best = r;
    }
    return best.labels;
  }
  function silhouette(X, labels) {
    const n2 = X.length, k = Math.max(...labels) + 1;
    const size = new Array(k).fill(0);
    labels.forEach((l) => size[l]++);
    let total = 0;
    for (let i = 0; i < n2; i++) {
      const s = new Array(k).fill(0);
      for (let j = 0; j < n2; j++) if (j !== i) s[labels[j]] += Math.sqrt(d2(X[i], X[j]));
      if (size[labels[i]] <= 1) continue;
      const a = s[labels[i]] / (size[labels[i]] - 1);
      let b = Infinity;
      for (let c = 0; c < k; c++) if (c !== labels[i] && size[c]) b = Math.min(b, s[c] / size[c]);
      total += (b - a) / Math.max(a, b);
    }
    return total / n2;
  }
  function jacobiEigen(S) {
    const n2 = S.length;
    const A = S.map((r) => [...r]);
    const V = Array.from({ length: n2 }, (_, i) => Array.from({ length: n2 }, (_2, j) => i === j ? 1 : 0));
    for (let sweep = 0; sweep < 100; sweep++) {
      let off = 0;
      for (let i = 0; i < n2; i++) for (let j = i + 1; j < n2; j++) off += A[i][j] ** 2;
      if (off < 1e-30) break;
      for (let p = 0; p < n2 - 1; p++) {
        for (let q = p + 1; q < n2; q++) {
          if (Math.abs(A[p][q]) < 1e-300) continue;
          const theta = (A[q][q] - A[p][p]) / (2 * A[p][q]);
          const t = Math.sign(theta || 1) / (Math.abs(theta) + Math.sqrt(theta * theta + 1));
          const c = 1 / Math.sqrt(t * t + 1), s = t * c;
          for (let k = 0; k < n2; k++) {
            const akp = A[k][p], akq = A[k][q];
            A[k][p] = c * akp - s * akq;
            A[k][q] = s * akp + c * akq;
          }
          for (let k = 0; k < n2; k++) {
            const apk = A[p][k], aqk = A[q][k];
            A[p][k] = c * apk - s * aqk;
            A[q][k] = s * apk + c * aqk;
          }
          for (let k = 0; k < n2; k++) {
            const vkp = V[k][p], vkq = V[k][q];
            V[k][p] = c * vkp - s * vkq;
            V[k][q] = s * vkp + c * vkq;
          }
        }
      }
    }
    const order = [...Array(n2).keys()].sort((a, b) => A[b][b] - A[a][a]);
    return { values: order.map((i) => A[i][i]), vectors: order.map((i) => V.map((row) => row[i])) };
  }
  function pca(X, nComp = 2) {
    const n2 = X.length, d = X[0].length;
    const cov = Array.from({ length: d }, (_, i) => Array.from({ length: d }, (_2, j) => sum3(X.map((r) => r[i] * r[j])) / (n2 - 1)));
    const { values, vectors } = jacobiEigen(cov);
    for (const v of vectors) {
      let big = 0;
      v.forEach((x, i) => {
        if (Math.abs(x) > Math.abs(v[big])) big = i;
      });
      if (v[big] < 0) for (let i = 0; i < d; i++) v[i] = -v[i];
    }
    const total = sum3(values);
    return {
      components: vectors.slice(0, nComp),
      variance: values.slice(0, nComp),
      ratio: values.slice(0, nComp).map((v) => v / total),
      transform: (x) => vectors.slice(0, nComp).map((v) => sum3(v.map((c, i) => c * x[i])))
    };
  }
  function nameCluster(r) {
    if (r.overall_kmh >= 40 || r.max_kmh >= 85) return "Highway runs";
    if (r.km < 4) return "Short hops";
    if (r.idle_share >= 0.33) return "Stop-and-go";
    return "City trips";
  }
  function cluster(t) {
    const cols = CLUSTER_FEATURES.map((f) => t.map((r) => r[f]));
    const mu = cols.map(mean2), sd = cols.map((c) => Math.sqrt(variance(c)));
    const X = t.map((r, i) => cols.map((c, j) => sd[j] ? (c[i] - mu[j]) / sd[j] : 0));
    const silh = {};
    for (let k = 2; k <= 6; k++) silh[k] = silhouette(X, kmeans(X, k, 20));
    const raw = kmeans(X, K, 50);
    const model = pca(X, 2);
    const ids = [...new Set(raw)].sort((a, b) => a - b);
    const prof = new Map(ids.map((c) => {
      const g = t.filter((_, i) => raw[i] === c);
      const col = (f) => g.map((r) => r[f]);
      return [c, {
        n: g.length,
        km: median(col("km")),
        overall_kmh: median(col("overall_kmh")),
        idle_share: median(col("idle_share")),
        max_kmh: median(col("max_kmh")),
        minutes: median(col("elapsed_min")),
        km_total: sum3(col("km"))
      }];
    }));
    const names = new Map(ids.map((c) => [c, nameCluster(prof.get(c))]));
    const seen = {};
    for (const c of by(ids, (c2) => -prof.get(c2).km)) {
      const nm = names.get(c);
      seen[nm] = (seen[nm] ?? 0) + 1;
      if (seen[nm] > 1) names.set(c, `${nm} (shorter)`);
    }
    const order = by(ids, (c) => -prof.get(c).overall_kmh);
    const remap = new Map(order.map((old, i) => [old, i]));
    const kmTotal = sum3(ids.map((c) => prof.get(c).km_total));
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
    CLUSTER_FEATURES.forEach((f, i) => {
      loadings[f] = model.components.map((c, j) => npRound(c[i] * Math.sqrt(model.variance[j]), 3));
    });
    return {
      t: out,
      clusters: { k: K, silhouette: silh, features: CLUSTER_FEATURES, explained_variance: nr(model.ratio, 4), loadings, profiles }
    };
  }
  function powerLaw(t) {
    const d = t.filter((r) => r.km >= 1 && r.elapsed_min >= 2);
    const x = d.map((r) => Math.log(r.km)), y = d.map((r) => Math.log(r.elapsed_min));
    const X = x.map((v) => [1, v]);
    const beta = lstsq(X, y);
    const fit = X.map((r) => r[0] * beta[0] + r[1] * beta[1]);
    const res = y.map((v, i) => v - fit[i]);
    const n2 = X.length, k = 2;
    const s = Math.sqrt(sum3(res.map((r) => r * r)) / (n2 - k));
    const XtXi = inv([[sum3(X.map((r) => r[0] * r[0])), sum3(X.map((r) => r[0] * r[1]))], [sum3(X.map((r) => r[1] * r[0])), sum3(X.map((r) => r[1] * r[1]))]]);
    const quad = (r) => r[0] * (XtXi[0][0] * r[0] + XtXi[0][1] * r[1]) + r[1] * (XtXi[1][0] * r[0] + XtXi[1][1] * r[1]);
    const stud = X.map((r, i) => res[i] / (s * Math.sqrt(1 - quad(r))));
    const lo = Math.min(...x), hi = Math.max(...x), step = (hi - lo) / 59;
    const gx = Array.from({ length: 60 }, (_, i) => i === 59 ? hi : lo + i * step);
    const G = gx.map((v) => [1, v]);
    const gfit = G.map((r) => r[0] * beta[0] + r[1] * beta[1]);
    const se = G.map((r) => s * Math.sqrt(1 + quad(r)));
    const top = d.map((r, i) => ({ r, stud: stud[i], expected: Math.exp(fit[i]) })).filter((o) => Math.abs(o.stud) > 2.5).sort((a, b) => b.stud - a.stud);
    return {
      a: beta[0],
      b: beta[1],
      s,
      r2: 1 - variance(res) / variance(y),
      n: n2,
      band: {
        km: nr(gx.map(Math.exp), 3),
        fit: nr(gfit.map(Math.exp), 2),
        lo: nr(gfit.map((v, i) => Math.exp(v - 1.96 * se[i])), 2),
        hi: nr(gfit.map((v, i) => Math.exp(v + 1.96 * se[i])), 2)
      },
      outliers: top.map(({ r, stud: sv, expected }) => ({
        id: r.trip_id,
        start: r.start_ts,
        km: pyRound(r.km, 1),
        minutes: pyRound(r.elapsed_min, 0),
        expected: pyRound(expected, 0),
        stud: pyRound(sv, 2),
        idle_min: r.idle_min
      }))
    };
  }
  function commuteReliability(t) {
    const out = {};
    for (const [key, a, b] of [["to_work", "Home", "Work"], ["to_home", "Work", "Home"]]) {
      const d = t.filter((r) => r.from_place === a && r.to_place === b);
      if (d.length < 8) continue;
      const m = d.map((r) => r.elapsed_min);
      const p5 = quantile(m, 0.05), p50 = median(m), p95 = quantile(m, 0.95), mu = mean2(m);
      const slots = groupBy(d, (r) => Math.floor(hourFrac(ms3(r.start_ts)) * 4) / 4);
      const bySlot = ascKeys(slots).filter((s) => slots.get(s).length >= 2).map((s) => {
        const e = slots.get(s).map((r) => r.elapsed_min);
        return [s, median(e), e.length, quantile(e, 0.25), quantile(e, 0.75)];
      });
      const wds = groupBy(d, (r) => dow2(ms3(r.start_ts)));
      out[key] = {
        n: d.length,
        free_flow: p5,
        median: p50,
        mean: mu,
        p95,
        pti: p95 / p5,
        bti: (p95 - mu) / mu,
        km: median(d.map((r) => r.km)),
        minutes: nr(m, 1),
        by_slot: bySlot,
        by_weekday: ascKeys(wds).map((w) => [w, median(wds.get(w).map((r) => r.elapsed_min))]),
        trips: d.map((r) => [r.start_ts, pyRound(r.elapsed_min, 1), pyRound(r.idle_min / Math.max(r.engine_min, 1), 3)])
      };
    }
    return Object.keys(out).length ? out : null;
  }
  function forecast(t, odoNow, today, horizon = 240, windowDays = 120) {
    const perDay = /* @__PURE__ */ new Map();
    for (const r of t) perDay.set(r.start_ts.slice(0, 10), (perDay.get(r.start_ts.slice(0, 10)) ?? 0) + r.km);
    const first = ms3(ascKeys(perDay)[0] + "T00:00:00"), last = ms3(today + "T00:00:00");
    const nDays = Math.round((last - first) / DAY3) + 1;
    const days = Array.from({ length: nDays }, (_, i) => first + i * DAY3);
    const daily = days.map((d) => perDay.get(dayIso(d)) ?? 0);
    const odo = new Array(nDays);
    let after = 0;
    for (let i = nDays - 1; i >= 0; i--) {
      odo[i] = odoNow - after;
      after += daily[i];
    }
    const recent = daily.slice(-windowDays);
    const mu = mean2(recent), sd = Math.sqrt(variance(recent, 1)), n2 = recent.length;
    const h = Array.from({ length: horizon }, (_, i) => i + 1);
    const mn = h.map((v) => odoNow + mu * v);
    const spread = h.map((v) => Math.sqrt(v * sd ** 2 + (v * sd / Math.sqrt(n2)) ** 2));
    const future = h.map((v) => last + v * DAY3);
    const cross = (level, series) => {
      const i = series.findIndex((v) => v >= level);
      return i < 0 ? null : dayIso(future[i]);
    };
    const milestones = [];
    for (let level = (Math.floor(odoNow / 5e3) + 1) * 5e3; level < Math.trunc(mn[horizon - 1]) + 1; level += 5e3) {
      milestones.push({
        km: level,
        p50: cross(level, mn),
        early: cross(level, mn.map((m, i) => m + 1.2816 * spread[i])),
        late: cross(level, mn.map((m, i) => m - 1.2816 * spread[i]))
      });
    }
    const weekly = /* @__PURE__ */ new Map();
    days.forEach((d, i) => {
      const lab = d + (6 - dow2(d)) % 7 * DAY3;
      weekly.set(lab, (weekly.get(lab) ?? 0) + daily[i]);
    });
    return {
      history: days.map((d, i) => [dayIso(d), pyRound(odo[i], 1)]),
      future: future.map((d, i) => [dayIso(d), pyRound(mn[i], 1), pyRound(mn[i] - 1.2816 * spread[i], 1), pyRound(mn[i] + 1.2816 * spread[i], 1)]),
      km_per_day: mu,
      sd_per_day: sd,
      window_days: windowDays,
      milestones,
      weekly: [...weekly].sort((a, b) => a[0] - b[0]).map(([d, v]) => [dayIso(d), pyRound(v, 1)])
    };
  }
  function coldStarts(t) {
    const edges = [0, 1 / 6, 0.5, 1, 2, 4, 8, 16, 1e9];
    const labels = ["<10 min", "10\u201330 min", "30\u201360 min", "1\u20132 h", "2\u20134 h", "4\u20138 h", "8\u201316 h", "16 h+"];
    const counts = new Array(8).fill(0);
    for (const r of t) if (ok(r.soak_h)) {
      const i = edges.findIndex((e, k) => k < 8 && r.soak_h >= e && r.soak_h < edges[k + 1]);
      if (i >= 0) counts[i]++;
    }
    const shortCold = t.filter((r) => r.cold && r.km < 5);
    return {
      labels,
      counts,
      cold_share: t.filter((r) => r.cold).length / t.length,
      short_cold: shortCold.length,
      short_cold_share: shortCold.length / t.length,
      short_cold_km: sum3(shortCold.map((r) => r.km)),
      threshold_h: COLD_SOAK_H
    };
  }
  function rank(xs) {
    const idx = xs.map((v, i) => i).filter((i) => ok(xs[i])).sort((a, b) => xs[a] - xs[b]);
    const out = xs.map(() => NaN);
    for (let i = 0; i < idx.length; ) {
      let j = i;
      while (j + 1 < idx.length && xs[idx[j + 1]] === xs[idx[i]]) j++;
      for (let k = i; k <= j; k++) out[idx[k]] = (i + j) / 2 + 1;
      i = j + 1;
    }
    return out;
  }
  function correlations(t) {
    const cols = {
      km: "Distance",
      elapsed_min: "Duration",
      avg_kmh: "Moving speed",
      overall_kmh: "Overall speed",
      max_kmh: "Top speed",
      idle_share: "Idle share",
      hour: "Start hour",
      soak_h: "Soak time",
      events: "Alerts"
    };
    const keys2 = Object.keys(cols);
    const ranks = keys2.map((k) => rank(t.map((r) => r[k])));
    const pear = (a, b) => {
      const ix = a.map((_, i) => i).filter((i) => ok(a[i]) && ok(b[i]));
      const xa = ix.map((i) => a[i]), xb = ix.map((i) => b[i]);
      const ma = mean2(xa), mb = mean2(xb);
      const cov = sum3(xa.map((v, i) => (v - ma) * (xb[i] - mb)));
      return cov / Math.sqrt(sum3(xa.map((v) => (v - ma) ** 2)) * sum3(xb.map((v) => (v - mb) ** 2)));
    };
    return { labels: Object.values(cols), matrix: ranks.map((a, i) => ranks.map((b, j) => npRound(i === j ? 1 : pear(a, b), 3))) };
  }
  var cleanOut = (o) => {
    if (Array.isArray(o)) return o.map(cleanOut);
    if (o && typeof o === "object") return Object.fromEntries(Object.entries(o).map(([k, v]) => [k, cleanOut(v)]));
    return typeof o === "number" && !Number.isFinite(o) ? null : o;
  };
  var pad22 = (n2) => String(n2).padStart(2, "0");
  var localIso = (d) => `${d.getFullYear()}-${pad22(d.getMonth() + 1)}-${pad22(d.getDate())}T${pad22(d.getHours())}:${pad22(d.getMinutes())}:${pad22(d.getSeconds())}`;
  function buildPerformance(tables, { today, odoNow, delta, fuelModel = null, now = /* @__PURE__ */ new Date() }) {
    const { trips, points } = tables;
    let t = tripFeatures(trips, delta);
    const hasGps = points.length > 0;
    let gf = [], va = null, pooled = null;
    if (hasGps) ({ gf, va, pooled } = gpsFeatures(points));
    const gfBy = new Map(gf.map((r) => [r.trip_id, r]));
    if (gf.length) {
      const blank = { rpa: NaN, stops: NaN, stops_per_km: NaN, p95_kmh: NaN, gps_secs: NaN, ...Object.fromEntries(BANDS.map((b) => [`band_${b[2]}`, NaN])) };
      t = t.map((r) => ({ ...gfBy.get(r.trip_id) ?? blank, ...r }));
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
        byCluster.push({ cluster: c, n: rows.length, share: bandCols.map((col) => sum3(rows.map((r, i) => r[col] * w[i])) / sum3(w)) });
      }
    }
    const months = groupBy(t, (r) => r.start_ts.slice(0, 7));
    const monthly = ascKeys(months).map((m) => {
      const g = months.get(m);
      const v = {
        km: sum3(g.map((r) => r.km)),
        trips: g.length,
        moving_kmh: median(g.map((r) => r.avg_kmh)),
        overall_kmh: median(g.map((r) => r.overall_kmh)),
        idle_share: median(g.map((r) => r.idle_share)),
        engine_h: sum3(g.map((r) => r.engine_min)) / 60,
        events: sum3(g.map((r) => r.events))
      };
      return { month: m, ...Object.fromEntries(Object.entries(v).map(([k, x]) => [k, pyRound(x, 3)])) };
    });
    let idleFuel = null;
    if (fuelModel) {
      const c = fuelModel.coef;
      idleFuel = { lph: c.idle_lph, litres: sum3(t.map((r) => r.idle_min)) / 60 * c.idle_lph };
    }
    const keep = [
      "trip_id",
      "start_ts",
      "km",
      "elapsed_min",
      "avg_kmh",
      "overall_kmh",
      "max_kmh",
      "idle_share",
      "soak_h",
      "cold",
      "cluster",
      "pc1",
      "pc2",
      "events",
      "rpa",
      "stops_per_km",
      "p95_kmh",
      ...bandCols
    ].filter((k) => k in t[0]);
    const tripsOut = t.map((r) => Object.fromEntries(keep.map((k) => [k, typeof r[k] === "number" && !Number.isInteger(r[k]) ? npRound(r[k], 4) : r[k]])));
    const engineH = sum3(t.map((r) => r.engine_min)) / 60;
    const kmAll = sum3(t.map((r) => r.km));
    return cleanOut({
      generated_at: localIso(now),
      delta_km_per_trip: delta,
      totals: {
        trips: t.length,
        km: kmAll,
        engine_h: engineH,
        km_per_engine_h: kmAll / engineH,
        routed: routed.length,
        rpa_median: routed.length ? median(routed.map((r) => r.rpa)) : null,
        stops_per_km_median: routed.length ? median(routed.map((r) => r.stops_per_km)) : null,
        idle_h: sum3(t.map((r) => r.idle_min)) / 60
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
      idle_fuel: idleFuel
    });
  }

  // src/index.js
  var ENTRY_NAME = /^[0-9a-f-]{36}\.json$/;
  var entriesIn = (files, folder) => Object.keys(files).filter((k) => k.startsWith(`log/${folder}/`) && ENTRY_NAME.test(k.slice(folder.length + 5))).sort().map((k) => files[k]);
  function runAll(files, { today, source } = {}) {
    const errors = [], warnings = [];
    const warn = (m) => warnings.push(String(m));
    const attempt = (page, fn) => {
      try {
        return fn();
      } catch (e) {
        errors.push({ page, message: e && e.message ? e.message : String(e) });
        return null;
      }
    };
    const tables = attempt("tables", () => loadTables(files));
    const odoNow = tables ? tables.snaps.filter((s) => s.odometer_km != null).at(-1)?.odometer_km ?? null : null;
    const fills = attempt("refuels", () => fillsFromRefuels(entriesIn(files, "refuels"), warn)) ?? [];
    const services = attempt("services", () => servicesFrom(entriesIn(files, "services"), warn)) ?? [];
    const maintenance = attempt("maintenance", () => maintenanceFrom(entriesIn(files, "maintenance"), warn)) ?? [];
    const fuel = tables && attempt("fuel", () => buildFuel(tables, fills, odoNow, source ? { source } : void 0));
    const delta = fuel?.calibration?.delta ?? 0;
    const data = tables && attempt("data", () => buildOverview(tables, files, { today, delta, fuel, services, maintenance }));
    const performance = tables && attempt("performance", () => buildPerformance(tables, { today, odoNow, delta, fuelModel: fuel ? fuel.model : null }));
    return { data: data || null, fuel: fuel || null, performance: performance || null, errors, warnings };
  }
  return __toCommonJS(index_exports);
})();
globalThis.I20Analytics = { runAll: __i20.runAll };
