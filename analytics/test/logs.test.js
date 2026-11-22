import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { compare } from "./parity.js";
import { csvPath, refuelsFromCsv } from "./helpers.js";
import { fillsFromRefuels, servicesFrom, maintenanceFrom } from "../src/logs.js";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const goldenPath = path.join(root, "tests", "golden", "fills.json");

const havePrivateArchive = fs.existsSync(path.join(root, "data", "raw")) && fs.existsSync(path.join(root, "tests", "golden", "fuel.json")) && fs.existsSync(path.join(root, "Sheet 1-Car Fuel.csv"));

test("fillsFromRefuels matches load_fills columns of the Python oracle", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  assert.ok(fs.existsSync(goldenPath), "tests/golden/fills.json missing");
  assert.ok(fs.existsSync(csvPath), "Sheet 1-Car Fuel.csv missing");
  const cols = ["date", "amount", "litres", "logged_km", "rate", "station", "brand", "imputed", "premium"];
  const pick = (rows) => rows.map((r) => Object.fromEntries(cols.map((c) => [c, r[c]])));
  const golden = JSON.parse(fs.readFileSync(goldenPath, "utf8"));
  const entries = refuelsFromCsv(fs.readFileSync(csvPath, "utf8"));
  assert.equal(entries.length, 28);
  const fills = fillsFromRefuels(entries);
  assert.deepEqual(compare(pick(golden), pick(fills), { tol: 1e-9 }), []);
  for (const f of fills) assert.deepEqual([f.full_tank, f.missed, f.time], [null, false, null]);
});

test("missing litres are imputed from amount and the entry's rate", () => {
  const e = { date: "2026-09-18", amount: 514.85, rate: 102.97, litres: null, station: "X", company: null, missed: false };
  const [f] = fillsFromRefuels([e]);
  assert.ok(Math.abs(f.litres - 5.0) < 1e-9);
  assert.equal(f.imputed, "litres");
  assert.equal(f.brand, "Unknown");
});

test("missing rate is amount / litres; missing both borrows the station's rate", () => {
  const base = { station: "A", company: "Jio", missed: false };
  const fills = fillsFromRefuels([
    { ...base, date: "2026-01-01", amount: 1000, litres: 10, rate: 100 },
    { ...base, date: "2026-01-05", amount: 500, litres: 5, rate: null },
    { ...base, date: "2026-01-09", amount: 1100, litres: null, rate: null },
    { ...base, station: "B", date: "2026-01-02", amount: 100, litres: 1, rate: 100 },
  ]);
  assert.equal(fills[1].date, "2026-01-02T00:00:00");
  const imp = fills.find((f) => f.date.startsWith("2026-01-05"));
  assert.equal(imp.rate, 100); assert.equal(imp.imputed, "rate");
  const lit = fills.find((f) => f.date.startsWith("2026-01-09"));
  assert.equal(lit.rate, 100); assert.equal(lit.litres, 11); assert.equal(lit.imputed, "litres");
});

test("servicesFrom and maintenanceFrom sort by date", () => {
  const s = servicesFrom([{ date: "2026-09-19", odometer_km: 2, parts: [] }, { date: "2026-03-01", odometer_km: 1 }]);
  assert.deepEqual(s.map((x) => x.odometer_km), [1, 2]);
  assert.deepEqual(s[0].parts, []);
  const m = maintenanceFrom([{ date: "2026-05-01", cost: 2 }, { date: "2026-04-01", cost: 1 }]);
  assert.deepEqual(m.map((x) => x.cost), [1, 2]);
});

test("id and entered_at are preserved; resets default to []", () => {
  const r = fillsFromRefuels([{ id: "r1", entered_at: "2026-10-25T18:31:07+05:30", date: "2026-01-01", amount: 1, litres: 1, rate: 1, station: "A" }]);
  assert.deepEqual([r[0].id, r[0].entered_at], ["r1", "2026-10-25T18:31:07+05:30"]);
  const s = servicesFrom([{ id: "s1", entered_at: "t", date: "2026-01-01", parts: [{ code: "x", qty: 3.6 }], photos: ["a.jpg"] }]);
  assert.deepEqual([s[0].id, s[0].entered_at, s[0].photos], ["s1", "t", ["a.jpg"]]);
  assert.deepEqual(s[0].parts[0].resets, []);
  assert.equal(maintenanceFrom([{ id: "m1", date: "2026-01-01", cost: 1 }])[0].id, "m1");
});

test("entries with schema > 1 are skipped with a warning; unknown fields ignored", () => {
  const warnings = [];
  const warn = (m) => warnings.push(m);
  const ok = { schema: 1, id: "a", date: "2026-01-01", amount: 1, litres: 1, rate: 1, station: "A", future_field: 1 };
  const fills = fillsFromRefuels([ok, { ...ok, id: "b", schema: 2 }], warn);
  assert.equal(fills.length, 1);
  assert.equal(servicesFrom([{ schema: 2, id: "c", date: "2026-01-01" }], warn).length, 0);
  assert.equal(maintenanceFrom([{ schema: 3, id: "d", date: "2026-01-01" }], warn).length, 0);
  assert.equal(warnings.length, 3);
});

test("missing amount is litres x rate and marked imputed", () => {
  const [f] = fillsFromRefuels([{ date: "2026-09-18", litres: 10, rate: 100, amount: null, station: "X", missed: false }]);
  assert.equal(f.amount, 1000);
  assert.equal(f.imputed, "amount");
});

test("a missed fill with nothing known stays null", () => {
  const [f] = fillsFromRefuels([{ date: "2026-09-18", litres: null, rate: null, amount: null, station: "X", missed: true }]);
  assert.deepEqual([f.amount, f.litres, f.imputed], [null, null, ""]);
});

test("entries without a valid date are skipped with a warning", () => {
  const warns = [];
  const fills = fillsFromRefuels([{ id: "bad", litres: 5 }, { id: "ok", date: "2026-09-18", litres: 5, rate: 100 }], (m) => warns.push(m));
  assert.deepEqual(fills.map((x) => x.id), ["ok"]);
  assert.equal(warns.length, 1);
  assert.match(warns[0], /bad/);
});
