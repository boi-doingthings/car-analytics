// Shared test helpers: real-archive loading and CSV -> refuel entries.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
export const rawDir = path.join(root, "data", "raw");
export const csvPath = path.join(root, "Sheet 1-Car Fuel.csv");
const MON = { Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6, Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12 };

/** Read every file under dir into Files; `data/raw` is mapped to `raw/`. */
export function readBook(dir) {
  const files = {};
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".json")) files["raw/" + path.relative(dir, p).split(path.sep).join("/")] = JSON.parse(fs.readFileSync(p, "utf8"));
    }
  })(dir);
  return files;
}

/** Minimal CSV parser (quoted fields, no embedded newlines). */
function parseCsv(text) {
  return text.split(/\r?\n/).filter((l) => l.length).map((line) => {
    const cells = [];
    let cur = "", q = false;
    for (const ch of line) {
      if (ch === '"') q = !q;
      else if (ch === "," && !q) { cells.push(cur); cur = ""; }
      else cur += ch;
    }
    cells.push(cur);
    return cells;
  });
}

/** CSV rows -> refuel entries, columns mapped 1:1 (docs/entry-schemas.md). */
export function refuelsFromCsv(text) {
  const [, ...rows] = parseCsv(text);
  const n = (s) => { const t = s.replace(/[₹,\s]/g, ""); return t === "" ? null : Number(t); };
  return rows.filter((r) => r.some((c) => c.trim())).map((r, i) => {
    const [, d, mon, y] = /(\d+) (\w{3}) (\d{4})/.exec(r[0]);
    return {
      schema: 1, id: `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`, entered_at: "2026-10-25T00:00:00",
      date: `${y}-${String(MON[mon]).padStart(2, "0")}-${d.padStart(2, "0")}`, time: null,
      amount: n(r[1]), station: r[2], litres: n(r[3]), odometer_km: n(r[4]), rate: n(r[5]),
      company: r[6].trim() || null,
      full_tank: null, missed: false, lat: null, lon: null, note: null,
    };
  });
}
