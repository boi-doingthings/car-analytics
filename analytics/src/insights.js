// Overview insights: places, hotspots, commute/rhythm findings and the service plan. Port of insights.build
// (the Python output is the oracle), plus two new outputs for the phone: running_cost and reminders.
import { latestRaw } from "./tables.js";
import { fmtDate, fmtFixed, fmtInt, fmtPercent, groupBy, haversineKm, median, npRound, pyRound, rint } from "./util.js";

export const TANK_L = 37;
export const CELL = 0.0015; // ~150 m grid for places
export const SLOW_KMH = 8;
const WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const DAY = 86400000;

const isNum = (v) => v != null && !Number.isNaN(v);
const sum = (xs) => { let s = 0; for (const v of xs) if (isNum(v)) s += v; return s; };
const ms = (iso) => Date.parse(iso.length === 10 ? iso + "T00:00:00Z" : iso + "Z");
const pad = (n) => String(n).padStart(2, "0");
const isoDay = (t) => { const d = new Date(t); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`; };
const addDays = (iso, n) => isoDay(ms(iso.slice(0, 10)) + n * DAY);
const daysBetween = (a, b) => Math.round((ms(a.slice(0, 10)) - ms(b.slice(0, 10))) / DAY); // a - b
const dow = (iso) => (new Date(ms(iso)).getUTCDay() + 6) % 7; // Monday = 0
const hourOf = (iso) => +iso.slice(11, 13);
const cmpStr = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const maxIdx = (xs) => xs.reduce((bi, v, i) => (v > xs[bi] ? i : bi), 0); // first maximum, like idxmax
const minIdx = (xs) => xs.reduce((bi, v, i) => (v < xs[bi] ? i : bi), 0);
const mean = (xs) => sum(xs) / xs.length;

// ---------- places ----------

const cellOf = (lat, lon) => (isNum(lat) && isNum(lon) ? `${rint(lat / CELL)}:${rint(lon / CELL)}` : "<NA>:<NA>");

/** Most frequent value; ties resolve to the smallest (pandas mode()). */
function mode(xs) {
  const c = new Map();
  for (const x of xs) c.set(x, (c.get(x) ?? 0) + 1);
  let best = null;
  for (const [k, v] of c) if (best === null || v > c.get(best) || (v === c.get(best) && k < best)) best = k;
  return best;
}

/** Places you start/end trips at: Home, Work, and Place N for anywhere with >= 6 visits. */
export function findPlaces(routed) {
  const ends = [
    ...routed.map((r) => ({ lat: r.start_lat, lon: r.start_lon, ts: r.start_ts, kind: "start" })),
    ...routed.map((r) => ({ lat: r.end_lat, lon: r.end_lon, ts: r.end_ts, kind: "end" })),
  ];
  for (const e of ends) e.cell = cellOf(e.lat, e.lon);
  const agg = [...groupBy(ends, (e) => e.cell)].sort((a, b) => cmpStr(a[0], b[0]))
    .map(([cell, es]) => ({ cell, lat: mean(es.map((e) => e.lat)), lon: mean(es.map((e) => e.lon)), visits: es.length }));
  const lastOfDay = [...groupBy([...routed].sort((a, b) => cmpStr(a.end_ts, b.end_ts)), (r) => r.date)].map(([, rs]) => rs.at(-1));
  const home = mode(lastOfDay.map((r) => cellOf(r.end_lat, r.end_lon)));
  const wd = ends.filter((e) => e.kind === "end" && dow(e.ts) < 5 && hourOf(e.ts) >= 7 && hourOf(e.ts) <= 11 && e.cell !== home);
  const work = wd.length ? mode(wd.map((e) => e.cell)) : null;
  // Ties: pandas' unstable quicksort put the later cell first in the oracle run; pinned here so numbering is deterministic.
  agg.sort((a, b) => b.visits - a.visits || cmpStr(b.cell, a.cell));
  let i = 1;
  const out = [];
  for (const a of agg) {
    let name = null;
    if (a.cell === home) name = "Home";
    else if (a.cell === work) name = "Work";
    else if (a.visits >= 6) name = `Place ${i++}`; // only places you return to are worth naming
    if (name) out.push({ ...a, name });
  }
  return out;
}

export function nearestPlace(lat, lon, places, withinKm = 0.35) {
  if (!isNum(lat) || !places.length) return null;
  const d = places.map((p) => haversineKm(lat, lon, p.lat, p.lon));
  const i = minIdx(d);
  return d[i] <= withinKm ? places[i].name : null;
}

// ---------- findings ----------

export function fmtMin(m) {
  m = pyRound(m);
  return m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`;
}

export function clock(h, suffix = true) {
  const hh = Math.trunc(h), mm = pyRound((h % 1) * 60);
  return `${hh % 12 || 12}:${pad(mm)}` + (suffix ? ` ${hh < 12 ? "am" : "pm"}` : "");
}

/** '8:30–9:00 am' for the half hour starting at h. */
export function halfHour(h) {
  const same = h < 12 === h + 0.5 < 12;
  return `${clock(h, !same)}–${clock(h + 0.5)}`;
}

/** Best vs worst half-hour departure slot (needs >= 3 trips per slot). */
export function commuteFinding(rows, direction) {
  if (rows.length < 8) return null;
  const slots = groupBy(rows, (r) => Math.floor((hourOf(r.start_ts) + +r.start_ts.slice(14, 16) / 60) * 2) / 2);
  const g = [...slots].filter(([, rs]) => rs.length >= 3).sort((a, b) => a[0] - b[0])
    .map(([slot, rs]) => ({ slot, med: median(rs.map((r) => r.elapsed_min)) }));
  if (g.length < 2) return null;
  const best = g[minIdx(g.map((x) => x.med))], worst = g[maxIdx(g.map((x) => x.med))];
  if (worst.med - best.med < 4) return `Your ${direction} takes about the same time whenever you leave.`;
  return `Leave at ${halfHour(best.slot)} and your ${direction} takes ${fmtFixed(best.med, 0)} min. `
    + `At ${halfHour(worst.slot)}, it's ${fmtFixed(worst.med, 0)}.`;
}

/** Where the car crawls: time under SLOW_KMH per ~200 m cell, ignoring the first/last minute of each trip
 *  and anything near a known place (parking). */
export function hotspots(points, routed, places) {
  if (!points.length) return [];
  const span = new Map(routed.map((r) => [r.trip_id, [ms(r.start_ts), ms(r.end_ts)]]));
  const slow = [];
  let prevTrip = null, prevT = null;
  for (const p of points) {
    const s = span.get(p.trip_id);
    if (!s) continue;
    const t = ms(p.t);
    if (!(t > s[0] + 60000 && t < s[1] - 60000)) continue;
    const dt = p.trip_id === prevTrip ? Math.min((t - prevT) / 1000, 30) : 0;
    prevTrip = p.trip_id; prevT = t;
    if (p.speed < SLOW_KMH) slow.push({ ...p, dt });
  }
  if (!slow.length) return [];
  const named = places.filter((p) => p.visits >= 3);
  const far = named.length
    ? slow.filter((p) => Math.min(...named.map((n) => haversineKm(p.lat, p.lon, n.lat, n.lon))) > 0.25)
    : slow;
  const cells = groupBy(far, (p) => `${rint(p.lat / 0.002)}:${rint(p.lon / 0.002)}`);
  return [...cells].sort((a, b) => cmpStr(a[0], b[0])).map(([, ps]) => ({
    lat: mean(ps.map((p) => p.lat)), lon: mean(ps.map((p) => p.lon)), seconds: sum(ps.map((p) => p.dt)),
    trips: new Set(ps.map((p) => p.trip_id)).size,
  })).filter((c) => c.trips >= 3).sort((a, b) => b.seconds - a.seconds).slice(0, 8)
    .map((c) => ({ lat: pyRound(c.lat, 5), lon: pyRound(c.lon, 5), minutes: pyRound(c.seconds / 60), trips: c.trips,
      per_trip: npRound(c.seconds / 60 / c.trips, 1) }));
}

export function addMonths(iso, months) {
  const y = +iso.slice(0, 4), m0 = +iso.slice(5, 7) - 1 + months, d = +iso.slice(8, 10);
  const yy = y + Math.floor(m0 / 12), mm = ((m0 % 12) + 12) % 12;
  return `${yy}-${pad(mm + 1)}-${pad(Math.min(d, 28))}`;
}

/** Next due date per Bluelink maintenance item. Items replaced at a logged service count from that visit;
 *  the rest assume the schedule was kept (every interval from 0 km / registration). */
export function servicePlan(files, odo, reg, pace, today, services) {
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
        let n = 1;
        while (addMonths(reg, everyMo * n) <= today) n++;
        timeDate = addMonths(reg, everyMo * n);
      }
    }
    const kmDate = pace ? addDays(today, Math.floor((kmDue - odo) / pace)) : null;
    const byTime = timeDate !== null && (kmDate === null || timeDate < kmDate);
    const due = byTime ? timeDate : kmDate;
    rows.push({
      item: item.itemId, every_km: everyKm, every_months: everyMo, due, days_left: due ? daysBetween(due, today) : null,
      trigger: byTime ? "time" : "distance", km_due: kmDue, last_done: last ? { date: last.date, km: last.odometer_km } : null,
    });
  }
  return rows.sort((a, b) => (a.days_left ?? 1e9) - (b.days_left ?? 1e9));
}

// ---------- new outputs ----------

/** Cost per km. Fuel uses the fuel model's own rate (modelled cost over the archived km it covers);
 *  service and other are logged spend over the whole odometer. fuel_rs is the archive-only modelled total. */
export function runningCost(odo, fuel, services, maintenance) {
  const fuelRs = fuel?.totals?.est_cost_total ?? 0;
  const serviceRs = sum(services.map((s) => s.total));
  const otherRs = sum(maintenance.map((m) => m.cost));
  const per = (v) => (odo ? v / odo : null);
  const fuelPer = fuel?.totals?.rs_per_km_model ?? (odo ? 0 : null);
  const total = fuelPer == null || !odo ? null : fuelPer + per(serviceRs) + per(otherRs);
  return {
    km: odo, fuel_rs: fuelRs, service_rs: serviceRs, other_rs: otherRs,
    per_km: { fuel: fuelPer, service: per(serviceRs), other: per(otherRs), total },
  };
}

/** Maintenance entries whose reminder date is today - 30 days or later, soonest first. */
export function reminders(maintenance, today) {
  const from = addDays(today, -30);
  return maintenance.filter((m) => m.reminder && m.reminder.slice(0, 10) >= from)
    .map((m) => ({ date: m.reminder.slice(0, 10), category: m.category, note: m.note ?? null, days_left: daysBetween(m.reminder, today) }))
    .sort((a, b) => cmpStr(a.date, b.date));
}

// ---------- build ----------

/** tables = loadTables(files); opts.today = 'YYYY-MM-DD'; fuel = buildFuel(...) result or null.
 *  Sets from_place/to_place on tables.trips in place (the other pages reuse them). */
export function buildOverview(tables, files, { today, delta, fuel = null, services = [], maintenance = [] }) {
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
  const odo = last && isNum(last.odometer_km) ? last.odometer_km : sum(trips.map((t) => t.distance_km));
  const cutoff = addDays(today, -90);
  const pace = sum(trips.filter((t) => t.date > cutoff).map((t) => t.distance_km)) / 90;

  const km = sum(trips.map((t) => t.distance_km)) + delta * trips.length;
  const totalMin = sum(trips.map((t) => t.total_min)), idleMin = sum(trips.map((t) => t.idle_min));
  const driveMin = sum(trips.map((t) => t.drive_min));
  const idleShare = idleMin / totalMin;

  // rhythm
  const wdOf = (t) => dow(t.start_ts), hrOf = (t) => hourOf(t.start_ts);
  const dates = trips.map((t) => t.date);
  const firstDay = dates.reduce((a, b) => (b < a ? b : a)), lastDay = dates.reduce((a, b) => (b > a ? b : a));
  const weeks = Math.max(daysBetween(lastDay, firstDay) / 7, 1);
  const byWd = Array.from({ length: 7 }, (_, d) => sum(trips.filter((t) => wdOf(t) === d).map((t) => t.distance_km)) / weeks);
  const rhythm = Array.from({ length: 7 }, () => new Array(24).fill(0));
  for (const t of trips) rhythm[wdOf(t)][hrOf(t)]++;
  const topWd = maxIdx(byWd);
  const weekdayAvg = mean(byWd.filter((_, d) => d !== topWd));

  // commute
  const toWork = routed.filter((t) => t.from_place === "Home" && t.to_place === "Work");
  const toHome = routed.filter((t) => t.from_place === "Work" && t.to_place === "Home");

  // idle by hour
  const hrIdle = [...groupBy(trips, hrOf)].sort((a, b) => a[0] - b[0])
    .map(([h, ts]) => ({ h, n: ts.length, share: sum(ts.map((t) => t.idle_min)) / sum(ts.map((t) => t.total_min)) }))
    .filter((r) => r.n >= 3);
  const worstHr = hrIdle.length ? hrIdle[maxIdx(hrIdle.map((r) => r.share))].h : null;

  const hs = hotspots(points, routed, places);
  const month = [...groupBy(trips, (t) => t.date.slice(0, 7))].sort((a, b) => cmpStr(a[0], b[0])).map(([m, ts]) => ({
    m, km: sum(ts.map((t) => t.distance_km)), trips: ts.length, drive: sum(ts.map((t) => t.drive_min)),
  }));
  const bestMonth = month[maxIdx(month.map((r) => r.km))];
  const longest = trips[maxIdx(trips.map((t) => t.distance_km ?? -Infinity))];
  const shortShare = trips.filter((t) => t.distance_km < 3).length / trips.length;
  const events = sum(trips.map((t) => (t.hard_brake ?? 0) + (t.rapid_accel ?? 0) + (t.overspeed ?? 0)));

  const findings = {
    hero: reg ? `Since ${fmtDate(reg, "%-d %B %Y")}, your i20 has covered ${fmtInt(odo)} km.` : `Your i20 has covered ${fmtInt(odo)} km.`,
    year: `${fmtDate(bestMonth.m + "-01", "%B")} was your biggest month at ${fmtInt(bestMonth.km)} km. `
      + `Your longest drive was ${fmtFixed(longest.distance_km, 0)} km on ${fmtDate(longest.start_ts, "%-d %B")}.`,
    rhythm: `${WEEKDAYS[topWd]}s are your big days: ${fmtFixed(byWd[topWd], 0)} km on average, `
      + `against ${fmtFixed(weekdayAvg, 0)} km on the other days.`,
    traffic: `You spend ${fmtPercent(idleShare)} of your time in the car standing still with the engine running: `
      + `${fmtFixed(idleMin / 60, 0)} hours so far`
      + (worstHr !== null ? `. It's worst on trips that start around ${clock(worstHr)}.` : "."),
    hotspots: hs.length >= 5
      ? `You've lost ${fmtFixed(sum(hs.slice(0, 5).map((h) => h.minutes)) / 60, 1)} hours crawling through these five spots.`
      : "Not enough routed trips to find hotspots yet.",
    commute_to_work: commuteFinding(toWork, "drive to work"),
    commute_to_home: commuteFinding(toHome, "drive home"),
    style: events
      ? `${events} flagged events in ${fmtInt(km)} km. That's one every ${fmtInt(km / events)} km.`
      : `Not one harsh brake, hard launch or speeding alert in ${fmtInt(km)} km.`,
    short: `${fmtPercent(shortShare)} of your trips are under 3 km. Those are the costliest kilometres you drive: `
      + "a cold engine burns noticeably more fuel.",
  };

  const routes = {};
  for (const [tid, g] of groupBy(points, (p) => p.trip_id)) {
    const t0 = ms(g[0].t);
    routes[tid] = g.map((p) => [pyRound(p.lat, 5), pyRound(p.lon, 5), pyRound(p.speed), Math.trunc((ms(p.t) - t0) / 1000)]);
  }

  // When the odometer crossed 10,000 km steps (first service milestones): odometer at the end of each day.
  const daily = [...groupBy(trips, (t) => t.date)].sort((a, b) => cmpStr(a[0], b[0])).map(([d, ts]) => [d, sum(ts.map((t) => t.distance_km)), ts.length]);
  const after = new Array(daily.length).fill(0); // km driven on later days
  for (let i = daily.length - 2; i >= 0; i--) after[i] = after[i + 1] + daily[i + 1][1];
  const odoByDay = daily.map((_, i) => odo - after[i]);
  const milestones = [];
  for (let mark = 10000; mark <= Math.trunc(odo); mark += 10000) {
    const i = odoByDay.findIndex((o) => o >= mark);
    if (i >= 0) milestones.push({ km: mark, date: daily[i][0] });
  }

  const out = {
    generated_at: new Date(Date.now() + 19800000).toISOString().slice(0, 19),
    vehicle: { model: vehicle.vehicleName ?? "i20", reg_date: reg, year: vehicle.year ?? null },
    status: last === null ? null : {
      odometer: odo, fuel_pct: last.fuel_pct, fuel_l: isNum(last.fuel_pct) ? rint((last.fuel_pct / 100) * TANK_L) : null,
      range_km: last.range_km, locked: last.door_lock == null ? null : !!last.door_lock, low_fuel: last.low_fuel == null ? null : !!last.low_fuel,
      as_of: last.status_time ?? null, park: isNum(last.park_lat) ? [last.park_lat, last.park_lon] : null,
    },
    totals: {
      km, trips: trips.length, days_driven: new Set(dates).size, hours: totalMin / 60, idle_hours: idleMin / 60,
      idle_share: idleShare, moving_kmh: km / (driveMin / 60), top_kmh: Math.max(...trips.map((t) => t.max_kmh ?? -Infinity)),
      coverage: odo ? km / odo : null, pace_90d: pace, first_day: firstDay, last_day: lastDay,
      routed_trips: routed.length, short_share: shortShare,
      hard_brake: sum(trips.map((t) => t.hard_brake)), rapid_accel: sum(trips.map((t) => t.rapid_accel)),
      overspeed: sum(trips.map((t) => t.overspeed)),
    },
    findings,
    days: daily.map(([d, k, n]) => [d, npRound(k, 1), n]),
    months: month.map((r) => [r.m, pyRound(r.km), r.trips, r.drive ? pyRound(r.km / (r.drive / 60), 1) : 0]),
    rhythm,
    weekday_km: byWd.map((v) => pyRound(v, 1)),
    idle_by_hour: hrIdle.map((r) => [r.h, npRound(r.share, 3), r.n]),
    trips: trips.map((r) => ({
      id: r.trip_id, start: r.start_ts, end: r.end_ts, km: r.distance_km, drive: r.drive_min, idle: r.idle_min,
      avg: r.avg_kmh, max: r.max_kmh, events: [r.hard_brake ?? 0, r.rapid_accel ?? 0, r.overspeed ?? 0],
      route: !!r.has_route, from: r.from_place, to: r.to_place,
    })),
    routes,
    places: places.slice(0, 12).map((p) => ({ name: p.name, lat: pyRound(p.lat, 5), lon: pyRound(p.lon, 5), visits: p.visits })),
    hotspots: hs,
    commute: Object.fromEntries([["to_work", toWork], ["to_home", toHome]].map(([k, rs]) =>
      [k, rs.map((r) => ({ start: r.start_ts, min: pyRound(r.elapsed_min), km: r.distance_km }))])),
    service: servicePlan(files, odo, reg, pace, today, services),
    services,
    milestones,
    fuel: snaps.filter((s) => isNum(s.fuel_pct)).map((s) => [s.taken_at, s.fuel_pct, s.range_km]),
    running_cost: runningCost(odo, fuel, services, maintenance),
    reminders: reminders(maintenance, today),
  };
  if (fuel) {
    out.tank = fuel.tank;
    out.fuel_rs_per_km = fuel.totals.rs_per_km_model;
  }
  return JSON.parse(JSON.stringify(out, (_, v) => (typeof v === "number" && !Number.isFinite(v) ? null : v)));
}
