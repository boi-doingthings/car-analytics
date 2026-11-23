// Single entry point for the iPhone app (bundled for JavaScriptCore): Files -> data/fuel/performance.
import { loadTables } from "./tables.js";
import { fillsFromRefuels, servicesFrom, maintenanceFrom } from "./logs.js";
import { buildFuel } from "./fuel.js";
import { buildOverview } from "./insights.js";
import { buildPerformance } from "./performance.js";

const ENTRY_NAME = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$/;
// Only log/<folder>/<uuid>.json: skips conflict copies ("<id> 2.json"), editor backups and stray files.
// Match the native reader's filename identity check before records can affect analytics.
const entriesIn = (files, folder, warn) => {
  const prefix = `log/${folder}/`;
  return Object.keys(files).filter((key) => key.startsWith(prefix) && ENTRY_NAME.test(key.slice(prefix.length)))
    .sort().flatMap((key) => {
      const entry = files[key];
      // Future versions retain their own schema warning path; their record shape is not ours to validate.
      if ((entry?.schema ?? 1) > 1) return [entry];
      const filenameID = key.slice(prefix.length, -5);
      if (typeof entry?.id !== "string" || entry.id !== filenameID) {
        const embedded = entry?.id;
        const actualID = embedded == null ? "missing"
          : typeof embedded === "string" ? JSON.stringify(embedded)
          : ["number", "boolean"].includes(typeof embedded) ? String(embedded)
          : `invalid ${Array.isArray(embedded) ? "array" : typeof embedded}`;
        // Use the filename stem so AnalyticsRunner can deduplicate its native file warning.
        warn(`skipping entry ${filenameID}: record ID does not match its filename (embedded ID: ${actualID})`);
        return [];
      }
      return [entry];
    });
};

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
  const fills = attempt("refuels", () => fillsFromRefuels(entriesIn(files, "refuels", warn), warn)) ?? [];
  const services = attempt("services", () => servicesFrom(entriesIn(files, "services", warn), warn)) ?? [];
  const maintenance = attempt("maintenance", () => maintenanceFrom(entriesIn(files, "maintenance", warn), warn)) ?? [];

  const fuel = tables && attempt("fuel", () => buildFuel(tables, fills, odoNow, source ? { source } : undefined));
  const delta = fuel?.calibration?.delta ?? 0;
  // Overview must run before performance: it adds from_place/to_place to the trips.
  const data = tables && attempt("data", () => buildOverview(tables, files, { today, delta, fuel, services, maintenance }));
  const performance = tables && attempt("performance", () =>
    buildPerformance(tables, { today, odoNow, delta, fuelModel: fuel ? fuel.model : null }));

  return { data: data || null, fuel: fuel || null, performance: performance || null, errors, warnings };
}
