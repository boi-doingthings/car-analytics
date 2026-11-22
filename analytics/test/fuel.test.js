import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { compare } from "./parity.js";
import { root, rawDir, csvPath, readBook, refuelsFromCsv } from "./helpers.js";
import { loadTables } from "../src/tables.js";
import { fillsFromRefuels } from "../src/logs.js";
import { buildFuel } from "../src/fuel.js";

const goldenPath = path.join(root, "tests", "golden", "fuel.json");

// Real archive, loaded once. Missing data/golden FAILS (never skips).
function setup() {
  assert.ok(fs.existsSync(rawDir), "data/raw missing");
  assert.ok(fs.existsSync(goldenPath), "tests/golden/fuel.json missing");
  assert.ok(fs.existsSync(csvPath), "Sheet 1-Car Fuel.csv missing");
  const tables = loadTables(readBook(rawDir));
  const odoNow = tables.snaps.filter((s) => s.odometer_km != null).at(-1).odometer_km;
  const entries = refuelsFromCsv(fs.readFileSync(csvPath, "utf8"));
  const golden = JSON.parse(fs.readFileSync(goldenPath, "utf8"));
  const run = (es) => buildFuel(tables, fillsFromRefuels(es), odoNow, { source: "Sheet 1-Car Fuel.csv" });
  return { tables, entries, golden, run };
}

const havePrivateArchive = fs.existsSync(path.join(root, "data", "raw")) && fs.existsSync(path.join(root, "tests", "golden", "fuel.json")) && fs.existsSync(path.join(root, "Sheet 1-Car Fuel.csv"));

test("buildFuel matches the Python oracle (fuel.json)", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { entries, golden, run } = setup();
  assert.deepEqual(compare(golden, run(entries), { tol: 1e-6 }), []);
});

test("full_tank=false on a large fill drops its brim and one interval", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { entries, golden, run } = setup();
  const i = entries.findIndex((e, k) => k > 3 && e.litres >= 30 && e.odometer_km != null);
  assert.ok(i > 0);
  const edited = entries.map((e, k) => (k === i ? { ...e, full_tank: false } : e));
  const out = run(edited);
  const date = edited[i].date;
  const fill = out.fills.find((f) => f.date === date && f.litres === edited[i].litres);
  assert.equal(fill.brim, false);
  assert.equal(out.intervals.length, golden.intervals.length - 1);
});

test("a missed fill with unknown litres marks its interval missing_fill and blanks the tank", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { entries, golden, run } = setup();
  const day = (s) => Date.parse(s + "T00:00:00Z");
  const iv = golden.intervals.find((r) => r.status === "ok" && day(r.to) - day(r.from) >= 2 * 86400000);
  const mid = new Date((day(iv.from) + day(iv.to)) / 2).toISOString().slice(0, 10);
  const missed = { schema: 1, id: "m1", entered_at: "2026-10-25T00:00:00", date: mid, time: null, amount: null,
    station: "?", litres: null, odometer_km: null, rate: null, company: null, full_tank: null, missed: true };
  const out = run([...entries, missed]);
  assert.equal(out.intervals.length, golden.intervals.length);
  const got = out.intervals.find((r) => r.from === iv.from && r.to === iv.to);
  assert.equal(got.status, "missing_fill");
  assert.ok(out.missing.some((m) => m.from === iv.from && m.to === iv.to));
  const [a, b] = out.tank.gaps.find(([x, y]) => x.startsWith(iv.from) && y.startsWith(iv.to));
  const inside = out.tank.points.filter((p) => p[0] >= a && p[0] < b);
  assert.ok(inside.length > 0);
  assert.ok(inside.every((p) => p[1] === null && p[2] === null));
  // The fit no longer uses that interval.
  assert.equal(out.model.n_intervals, golden.model.n_intervals - 1);
  // A missed fill with known litres is an ordinary fill: same intervals, all still ok where they were.
  const known = run([...entries, { ...missed, litres: 5, amount: 500, rate: 100 }]);
  assert.equal(known.intervals.find((r) => r.from === iv.from && r.to === iv.to).status, "ok");
});

test("buildFuel returns null without fills or trips", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { tables } = setup();
  assert.equal(buildFuel(tables, [], 1000), null);
  assert.equal(buildFuel({ ...tables, trips: [] }, fillsFromRefuels([]), 1000), null);
});

const blankEntry = (date, extra = {}) => ({ schema: 1, id: "x" + date, entered_at: "2026-10-25T00:00:00", date, time: null,
  amount: null, station: "?", litres: null, odometer_km: null, rate: null, company: null, full_tank: null, missed: true, ...extra });

test("a missed unknown-litres fill after the last brim blanks the tank to the end", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { entries, golden, run } = setup();
  const base = run(entries);
  const last = base.tank.points.at(-1);
  assert.notEqual(last[1], null);
  const out = run([...entries, blankEntry("2026-10-20")]);
  assert.equal(out.intervals.length, golden.intervals.length);
  const [a, b] = out.tank.gaps.at(-1);
  assert.ok(a.startsWith("2026-10-20"));
  const inside = out.tank.points.filter((p) => p[0] >= a && p[0] < b);
  assert.ok(inside.length > 0);
  assert.ok(inside.every((p) => p[1] === null && p[2] === null));
  assert.equal(out.tank.points.at(-1)[1], null);
  // points before the fill are untouched
  assert.deepEqual(out.tank.points.filter((p) => p[0] < a), base.tank.points.filter((p) => p[0] < a));
});

test("with fewer than 2 usable intervals, r2 and the LOO errors are null; output stays finite", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { entries, run } = setup();
  const brims = entries.filter((e) => e.litres >= 30 && e.odometer_km != null && e.date >= "2025-12-01").slice(0, 3);
  const out = run(brims);
  assert.equal(out.intervals.filter((r) => r.status === "ok").length, 1);
  assert.equal(out.model.n_intervals, 1);
  assert.deepEqual([out.model.r2, out.model.loo_mae, out.model.naive_loo_mae], [null, null, null]);
  assert.ok(out.model.coef.city_l100 > 0);
  assert.ok(!JSON.stringify(out).includes("Infinity"));
});

test("degenerate intervals (no distance) are excluded from the fit and not counted as missing fuel", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { entries, golden, run } = setup();
  const iv = golden.intervals.find((r) => r.status === "ok" && r.trips > 10);
  const day = (s) => Date.parse(s + "T00:00:00Z");
  const mid = new Date((day(iv.from) + day(iv.to)) / 2).toISOString().slice(0, 10);
  const two = [0, 1].map((k) => blankEntry(mid, { id: "d" + k, missed: false, litres: 31, amount: 3100, rate: 100, full_tank: true }));
  const out = run([...entries, ...two]);
  const deg = out.intervals.filter((r) => r.status === "degenerate");
  assert.equal(deg.length, 1);
  assert.ok(deg[0].from === mid && deg[0].to === mid);
  assert.ok(!out.missing.some((m) => m.from === mid));
  assert.ok(out.fitted ?? out.model.fitted.every((f) => !(f.from === mid && f.to === mid)));
  assert.ok(out.model.fitted.every((f) => !(f.from === mid && f.to === mid)));
  assert.ok(Number.isFinite(out.model.coef.city_l100) && Number.isFinite(out.model.r2));
});

test("full_tank=true on a small fill is a brim", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { entries, golden, run } = setup();
  const i = entries.findIndex((e, k) => k > 3 && e.litres < 30 && e.odometer_km != null);
  const edited = entries.map((e, k) => (k === i ? { ...e, full_tank: true } : e));
  const out = run(edited);
  const fill = out.fills.find((f) => f.date === edited[i].date && f.litres === edited[i].litres);
  assert.equal(fill.brim, true);
  assert.equal(out.intervals.length, golden.intervals.length + 1);
});

test("no fill with a rate gives null costs instead of throwing", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { entries, run } = setup();
  const noRate = entries.map((e) => ({ ...e, rate: null, amount: null }));
  const out = run(noRate);
  assert.ok(out === null || out.trips.every((t) => t.cost === null));
});
