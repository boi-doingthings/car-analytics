// Log entries (one JSON per refuel / service / maintenance entry) -> the tables the fuel model and
// insights consume. Mirrors fuel.load_fills and insights.load_services. Schemas: docs/entry-schemas.md.
import { median } from "./util.js";

const PREMIUM_MARKUP = 1.08;
const num = (v) => (v == null || Number.isNaN(v) ? null : v);
const day = (iso) => Date.parse(iso.slice(0, 10) + "T00:00:00Z");

/** Entries without a valid date, or with schema > 1, are skipped with a warning (never a crash); unknown fields are ignored. */
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

const byDate = (a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0);
/** Copy sorted by ISO date; Array.prototype.sort is stable. */
const sortedByDate = (xs) => [...xs].sort(byDate);

/** Refuel entries -> fills (load_fills columns + full_tank, missed, time). */
export function fillsFromRefuels(entries, warn = console.warn) {
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
    time: e.time ?? null,
  }));

  // Rate from amount / litres where both are known.
  const needRate = f.map((r) => r.rate === null && r.litres !== null && r.amount !== null);
  f.forEach((r, i) => {
    if (needRate[i]) { r.rate = r.amount / r.litres; r.imputed = "rate"; }
  });

  // Litres from amount / rate; rate unknown too -> borrow the same station's rate, else the nearest fill's.
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
      if (d < best) { best = d; near = x; }
    }
    r.rate = near.rate;
    r.litres = r.amount / r.rate;
    r.imputed = "litres";
  });

  // Amount from litres x rate (an entry saved with just litres and a rate).
  for (const r of f) {
    if (r.amount === null && r.litres !== null && r.rate !== null) { r.amount = r.litres * r.rate; r.imputed = "amount"; }
  }

  const out = sortedByDate(f);
  const cut = median(out.map((r) => r.rate)) * PREMIUM_MARKUP;
  for (const r of out) r.premium = r.rate !== null && r.rate > cut;
  return out.map(({ id, entered_at, date, amount, litres, logged_km, rate, station, brand, imputed, premium, full_tank, missed, time }) =>
    ({ id, entered_at, date, amount, litres, logged_km, rate, station, brand, imputed, premium, full_tank, missed, time }));
}

/** Service entries -> load_services() shape (visit fields), oldest first. */
export function servicesFrom(entries, warn = console.warn) {
  return sortedByDate(readable(entries, warn)).map((e) => ({
    id: e.id, entered_at: e.entered_at,
    date: e.date, odometer_km: e.odometer_km, kind: e.kind, workshop: e.workshop, invoice: e.invoice,
    parts: (e.parts ?? []).map((p) => ({ ...p, resets: p.resets ?? [] })), labour: e.labour ?? [],
    parts_total: e.parts_total, gst: e.gst, total: e.total, notes: e.notes, photos: e.photos ?? [],
  }));
}

/** Maintenance entries, oldest first. */
export function maintenanceFrom(entries, warn = console.warn) {
  return sortedByDate(readable(entries, warn)).map((e) => ({ ...e }));
}
