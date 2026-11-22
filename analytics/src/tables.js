// Raw Bluelink JSON files -> analytics tables. Port of build_db.py + insights.load/points_with_speed/latest_raw.
import { haversineKm, median } from "./util.js";

const pad = (n, w = 2) => String(n).padStart(w, "0");
const isoOf = (ms) => {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
};
const msOf = (y, mo, d, h, mi, s) => Date.UTC(+y, +mo - 1, +d, +h, +mi, +s);

/** '20260701085005' -> '2026-07-01T08:50:05' (null when missing/short). */
function ts(s) {
  if (!s || s.length < 14) return null;
  return `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}T${s.slice(8, 10)}:${s.slice(10, 12)}:${s.slice(12, 14)}`;
}
const msOfTs = (s) => msOf(s.slice(0, 4), s.slice(4, 6), s.slice(6, 8), s.slice(8, 10), s.slice(10, 12), s.slice(12, 14));
const isoMs = (iso) => Date.parse(iso + "Z");
const n = (v) => v ?? null;
const add = (a, b) => (a == null || b == null ? null : a + b);

const keys = (files, re) => Object.keys(files).filter((k) => !k.endsWith(".meta.json") && re.test(k)).sort();

function buildDays(files) {
  const rows = new Map();
  for (const k of keys(files, /^raw\/days\/[^/]+\/[^/]+\.json$/)) {
    const vid = k.split("/")[2];
    for (const d of (files[k].resMsg || {}).dayTripList || []) {
      const day = `${d.tripDay.slice(0, 4)}-${d.tripDay.slice(4, 6)}-${d.tripDay.slice(6)}`;
      const key = `${vid}|${day}`;
      rows.delete(key); // INSERT OR REPLACE moves the row to the end
      rows.set(key, {
        vehicle_id: vid, day, trip_count: n(d.dayTripCnt), distance_km: n(d.tripDist), drive_min: n(d.tripDrvTime),
        idle_min: n(d.tripIdleTime), avg_kmh: n(d.tripAvgSpeed), max_kmh: n(d.tripMaxSpeed),
      });
    }
  }
  return [...rows.values()];
}

function buildTrips(files) {
  const trips = new Map();
  const points = [];
  for (const k of keys(files, /^raw\/trips\/[^/]+\/[^/]+\.json$/)) {
    const vid = k.split("/")[2];
    const t = (files[k].resMsg || {}).tripInfo;
    if (!t) continue;
    const pts = t.tripList || [];
    const hasRoute = pts.length > 1; // routes are purged after ~3 months; coords only trustworthy with a route
    const start = t.tripStartCoord || {}, end = t.tripEndCoord || {};
    const tripId = t.tripStartTime;
    const key = `${vid}|${tripId}`;
    trips.delete(key);
    trips.set(key, {
      vehicle_id: vid, trip_id: tripId, day: ts(tripId).slice(0, 10), start_ts: ts(tripId), end_ts: ts(t.tripEndTime),
      distance_km: n(t.tripDist), drive_min: n(t.tripDrvTime), idle_min: n(t.tripIdleTime),
      avg_kmh: n(t.tripAvgSpeed), max_kmh: n(t.tripMaxSpeed),
      hard_brake: n(t.tripHardBreakingTime), rapid_accel: n(t.tripRapidAccelationTime), overspeed: n(t.tripExcessiveSpeedTime),
      start_lat: hasRoute ? n(start.lat) : null, start_lon: hasRoute ? n(start.lon) : null,
      end_lat: hasRoute ? n(end.lat) : null, end_lon: hasRoute ? n(end.lon) : null,
      gps_points: pts.length, has_route: hasRoute ? 1 : 0,
    });
    if (hasRoute) {
      let dayMs = msOf(tripId.slice(0, 4), tripId.slice(4, 6), tripId.slice(6, 8), 0, 0, 0);
      let prev = null;
      pts.forEach((p, i) => {
        const c = String(p.tripTime).padStart(6, "0");
        if (prev !== null && c < prev) dayMs += 86400000; // trip crossed midnight
        prev = c;
        points.push({
          vehicle_id: vid, trip_id: tripId, seq: i,
          ts: isoOf(dayMs + (+c.slice(0, 2) * 3600 + +c.slice(2, 4) * 60 + +c.slice(4, 6)) * 1000),
          lat: p.lat, lon: p.lon,
        });
      });
    }
  }
  return { trips: [...trips.values()], points };
}

function buildSnapshots(files) {
  const dirs = new Map();
  for (const k of keys(files, /^raw\/snapshots\/[^/]+\/[^/]+\/[^/]+\.json$/)) {
    const [, , vid, stamp] = k.split("/");
    dirs.set(`${vid}/${stamp}`, { vid, stamp });
  }
  const rows = [];
  for (const [dir, { vid, stamp }] of dirs) {
    const part = (name) => (files[`raw/snapshots/${dir}/${name}.json`]?.resMsg) || {};
    const status = part("status_latest"), loc = part("location_park"), maint = part("maintenance_alert");
    const coord = loc.coord || {};
    const hasStatus = Object.keys(status).length > 0;
    rows.push({
      vehicle_id: vid,
      taken_at: `${stamp.slice(0, 4)}-${stamp.slice(4, 6)}-${stamp.slice(6, 8)}T${stamp.slice(9, 11)}:${stamp.slice(11, 13)}:${stamp.slice(13, 15)}`,
      status_time: ts(status.time), odometer_km: n(maint.odometer), fuel_pct: n(status.fuelLevel),
      range_km: n(status.dte?.value),
      low_fuel: hasStatus ? +Boolean(status.lowFuelLight) : null,
      door_lock: hasStatus ? +Boolean(status.doorLock) : null,
      engine_on: hasStatus ? +Boolean(status.engine) : null,
      battery_state: n(status.battery?.batState),
      park_lat: n(coord.lat), park_lon: n(coord.lon), park_time: ts(loc.time),
    });
  }
  return rows;
}

const byKey = (f) => (a, b) => (f(a) < f(b) ? -1 : f(a) > f(b) ? 1 : 0); // Array.sort is stable

/** Breadcrumbs share one timestamp (~6 per minute): spread them evenly over the gap to the next timestamp
 *  (60 s after the last). Returns points sorted by (trip_id, seq) as {r, tsSec, offNs}: exact time = tsSec + offNs / 1e9. */
export function breadcrumbTimes(points) {
  const p = [...points].sort((a, b) => (a.trip_id < b.trip_id ? -1 : a.trip_id > b.trip_id ? 1 : a.seq - b.seq));
  const groups = new Map(); // trip|ts -> {size, next}
  const lastOfTrip = new Map();
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
  const seen = new Map();
  return p.map((r) => {
    const g = `${r.trip_id}|${r.ts}`;
    const grp = groups.get(g);
    const k = seen.get(g) ?? 0;
    seen.set(g, k + 1);
    const tsSec = isoMs(r.ts) / 1000;
    const gap = grp.nextTs == null ? 60 : Math.max(1, isoMs(grp.nextTs) / 1000 - tsSec);
    const offNs = Math.round((k / grp.size) * gap * 1e9);
    return { r, tsSec, offNs };
  });
}

/** Breadcrumb points with spread time `t` (ms string) and smoothed `speed`. */
export function pointsWithSpeed(points) {
  const rows = breadcrumbTimes(points);
  const out = [];
  let i = 0;
  while (i < rows.length) {
    let j = i;
    while (j < rows.length && rows[j].r.trip_id === rows[i].r.trip_id) j++;
    const raw = [];
    for (let a = i; a < j; a++) {
      if (a === i) { raw.push(0); continue; }
      const q = rows[a - 1], c = rows[a];
      const dKm = haversineKm(q.r.lat, q.r.lon, c.r.lat, c.r.lon);
      const dH = (c.tsSec - q.tsSec + (c.offNs - q.offNs) / 1e9) / 3600;
      raw.push(dH > 0 ? Math.min(dKm / dH, 160) : 0);
    }
    for (let a = 0; a < raw.length; a++) {
      const { r, tsSec, offNs } = rows[i + a];
      const tMs = Math.floor(tsSec * 1000 + offNs / 1e6);
      out.push({
        ...r,
        t: `${isoOf(tMs)}.${pad(((tMs % 1000) + 1000) % 1000, 3)}`,
        speed: median(raw.slice(Math.max(0, a - 2), a + 3)),
      });
    }
    i = j;
  }
  return out;
}

/** Files -> {trips, points, snaps, days}; rows ordered as insights.load() / the SQL ORDER BY. */
export function loadTables(files) {
  const { trips, points } = buildTrips(files);
  for (const t of trips) {
    t.date = t.start_ts.slice(0, 10);
    t.total_min = add(t.drive_min, t.idle_min); // Hyundai's drive time excludes idling
    t.elapsed_min = t.end_ts == null ? null : (isoMs(t.end_ts) - isoMs(t.start_ts)) / 60000;
  }
  return {
    trips: trips.sort(byKey((r) => r.start_ts)),
    points: pointsWithSpeed(points),
    snaps: buildSnapshots(files).sort(byKey((r) => r.taken_at)),
    days: buildDays(files),
  };
}

/** resMsg of the newest snapshot's `<name>.json` ({} when none). */
export function latestRaw(files, name) {
  const re = new RegExp(`^raw/snapshots/[^/]+/[^/]+/${name}\\.json$`);
  const ks = Object.keys(files).filter((k) => re.test(k)).sort();
  return ks.length ? files[ks[ks.length - 1]].resMsg || {} : {};
}
