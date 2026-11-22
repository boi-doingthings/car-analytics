// Single entry point for the iPhone app (bundled for JavaScriptCore): Files -> data/fuel/performance.
import { loadTables } from "./tables.js";
import { fillsFromRefuels, servicesFrom, maintenanceFrom } from "./logs.js";
import { buildFuel } from "./fuel.js";
import { buildOverview } from "./insights.js";
import { buildPerformance } from "./performance.js";

const ENTRY_NAME = /^[0-9a-f-]{36}\.json$/;
// Only log/<folder>/<uuid>.json: skips conflict copies ("<id> 2.json"), editor backups and stray files.
const entriesIn = (files, folder) =>
  Object.keys(files).filter((k) => k.startsWith(`log/${folder}/`) && ENTRY_NAME.test(k.slice(folder.length + 5))).sort().map((k) => files[k]);

/**
 * files: {"raw/...": json, "log/refuels/<id>.json": json, "log/services/...", "log/maintenance/..."}.
 * opts: {today: "YYYY-MM-DD", source?: label stored in fuel.source}.
 * Never throws for one failing page: a failed output is null and `errors` lists {page, message}.
 * `warnings` collects skipped-entry messages (no console: JavaScriptCore has none in a bare context).
 */
export function runAll(files, { today, source } = {}) {
  const errors = [], warnings = [];
  const warn = (m) => warnings.push(String(m));
  const attempt = (page, fn) => {
    try { return fn(); } catch (e) { errors.push({ page, message: e && e.message ? e.message : String(e) }); return null; }
  };

  const tables = attempt("tables", () => loadTables(files));
  const odoNow = tables ? (tables.snaps.filter((s) => s.odometer_km != null).at(-1)?.odometer_km ?? null) : null;
  const fills = attempt("refuels", () => fillsFromRefuels(entriesIn(files, "refuels"), warn)) ?? [];
  const services = attempt("services", () => servicesFrom(entriesIn(files, "services"), warn)) ?? [];
  const maintenance = attempt("maintenance", () => maintenanceFrom(entriesIn(files, "maintenance"), warn)) ?? [];

  const fuel = tables && attempt("fuel", () => buildFuel(tables, fills, odoNow, source ? { source } : undefined));
  const delta = fuel?.calibration?.delta ?? 0;
  // Overview must run before performance: it adds from_place/to_place to the trips.
  const data = tables && attempt("data", () => buildOverview(tables, files, { today, delta, fuel, services, maintenance }));
  const performance = tables && attempt("performance", () =>
    buildPerformance(tables, { today, odoNow, delta, fuelModel: fuel ? fuel.model : null }));

  return { data: data || null, fuel: fuel || null, performance: performance || null, errors, warnings };
}
