import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { compare } from "./parity.js";
import { root, rawDir, csvPath, readBook, refuelsFromCsv } from "./helpers.js";
import { loadTables } from "../src/tables.js";
import { fillsFromRefuels, servicesFrom, maintenanceFrom } from "../src/logs.js";
import { buildFuel } from "../src/fuel.js";
import { buildOverview, clock, halfHour, fmtMin, addMonths, reminders, runningCost } from "../src/insights.js";
import { rint, pyRound, npRound, fmtPercent } from "../src/util.js";

const goldenPath = path.join(root, "tests", "golden", "data.json");
const TODAY = "2026-10-25";

function setup() {
  assert.ok(fs.existsSync(rawDir), "data/raw missing");
  assert.ok(fs.existsSync(goldenPath), "tests/golden/data.json missing");
  assert.ok(fs.existsSync(csvPath), "Sheet 1-Car Fuel.csv missing");
  const files = readBook(rawDir);
  const tables = loadTables(files);
  const odoNow = tables.snaps.filter((s) => s.odometer_km != null).at(-1).odometer_km;
  const fuel = buildFuel(tables, fillsFromRefuels(refuelsFromCsv(fs.readFileSync(csvPath, "utf8"))), odoNow, { source: "x" });
  const log = JSON.parse(fs.readFileSync(path.join(root, "service_log.json"), "utf8")).services;
  const services = servicesFrom(log);
  const golden = JSON.parse(fs.readFileSync(goldenPath, "utf8"));
  const run = (maintenance = []) => buildOverview(tables, files, { today: TODAY, delta: fuel.calibration.delta, fuel, services, maintenance });
  return { golden, run };
}

// The app's services carry id/entered_at/photos and `resets: []`; the Python oracle's raw log entries do not.
const bare = (data) => ({
  ...data,
  services: data.services.map(({ id, entered_at, photos, ...s }) => ({
    ...s, parts: s.parts.map(({ resets, ...p }) => (resets.length ? { ...p, resets } : p)),
  })),
});

const havePrivateArchive = fs.existsSync(path.join(root, "data", "raw")) && fs.existsSync(path.join(root, "tests", "golden", "fuel.json")) && fs.existsSync(path.join(root, "Sheet 1-Car Fuel.csv"));

test("buildOverview matches the Python oracle (data.json)", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { golden, run } = setup();
  const out = bare(run());
  assert.deepEqual(compare(golden, out, { ignore: ["generated_at", "running_cost", "reminders"], tol: 1e-6 }), []);
});

test("running_cost sums fuel model, service visits and maintenance", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { golden, run } = setup();
  const out = run([{ id: "m", date: "2026-10-01", category: "tyres", cost: 1000, note: null, reminder: null }]);
  const rc = out.running_cost;
  assert.equal(rc.service_rs, 5669);
  assert.equal(rc.other_rs, 1000);
  assert.equal(rc.km, golden.status.odometer);
  assert.ok(rc.fuel_rs > 0);
  // Fuel per km is the model's rate over the archived km, not archive cost over the whole odometer.
  assert.equal(rc.per_km.fuel, out.fuel_rs_per_km);
  assert.ok(rc.per_km.fuel > rc.fuel_rs / rc.km);
  assert.ok(Math.abs(rc.per_km.service - 5669 / rc.km) < 1e-12);
  assert.ok(Math.abs(rc.per_km.total - (rc.per_km.fuel + (5669 + 1000) / rc.km)) < 1e-12);
});

test("reminders: dated >= today - 30 days, sorted, with days_left", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const m = (date, reminder, category = "puc") => ({ date: "2026-01-01", category, cost: 0, note: "n", reminder });
  const out = reminders(maintenanceFrom([m("", "2026-11-04"), m("", "2026-09-25", "wash"), m("", "2026-09-24", "old"), m("", null), m("", "2026-10-26", "wipers")]), TODAY);
  assert.deepEqual(out.map((r) => [r.date, r.category, r.days_left]),
    [["2026-09-25", "wash", -30], ["2026-10-26", "wipers", 1], ["2026-11-04", "puc", 10]]);
  assert.deepEqual(Object.keys(out[0]), ["date", "category", "note", "days_left"]);
  const { run } = setup();
  const r = run([{ date: "2026-01-01", category: "puc", cost: 0, note: null, reminder: "2026-11-04" }]).reminders;
  assert.equal(r.find((x) => x.category === "puc").days_left, 10);
});

test("runningCost with no odometer or fuel model does not divide by zero", () => {
  const rc = runningCost(0, null, [], []);
  assert.equal(rc.fuel_rs, 0);
  assert.equal(rc.per_km.total, null);
});

test("clock / halfHour / fmtMin / addMonths match insights.py", () => {
  assert.equal(clock(9), "9:00 am");
  assert.equal(clock(12.5), "12:30 pm");
  assert.equal(clock(0), "12:00 am");
  assert.equal(clock(16.5, false), "4:30");
  assert.equal(halfHour(8.5), "8:30–9:00 am");
  assert.equal(halfHour(11.5), "11:30 am–12:00 pm");
  assert.equal(fmtMin(59.5), "1 h 0 min");
  assert.equal(fmtMin(25.4), "25 min");
  assert.equal(addMonths("2025-11-25", 12), "2026-11-25");
  assert.equal(addMonths("2025-12-31", 2), "2026-02-28");
  assert.equal(addMonths("2025-11-25", 14), "2027-01-25");
});

test("rounding helpers: Python vs numpy semantics, half-even", () => {
  assert.deepEqual([0.5, 1.5, 2.5, -0.5, -1.5, -2.5, -3.5, 3.5, 2.4].map(rint), [0, 2, 2, -0, -2, -2, -4, 4, 2]);
  assert.equal(pyRound(2.675, 2), 2.67);
  assert.equal(pyRound(0.5), 0);
  assert.equal(pyRound(28.4341249, 5), 28.43412);
  assert.equal(npRound(2.675, 2), 2.68); // numpy scales first: 2.675 * 100 = 267.5 -> rint -> 268
  assert.equal(npRound(0.25, 1), 0.2);
  assert.equal(fmtPercent(0.2590967741935484), "26%");
  assert.equal(fmtPercent(0.125, 0), "12%");
});
