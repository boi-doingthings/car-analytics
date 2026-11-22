import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { compare } from "./parity.js";
import { readBook } from "./helpers.js";
import { loadTables, latestRaw } from "../src/tables.js";
import { fmtInt, fmtFixed, fmtDate, median, quantile, solve, inv, lstsq, groupBy, haversineKm } from "../src/util.js";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const rawDir = path.join(root, "data", "raw");
const goldenPath = path.join(root, "tests", "golden", "tables.json");
const have = fs.existsSync(rawDir) && fs.existsSync(goldenPath);

test("loadTables matches the Python oracle", { skip: !have && "no data/golden" }, () => {
  const golden = JSON.parse(fs.readFileSync(goldenPath, "utf8"));
  const files = readBook(rawDir);
  const { trips, points, snaps, days } = loadTables(files);
  assert.deepEqual(compare(golden.trips, trips, { tol: 1e-9 }), []);
  assert.deepEqual(compare(golden.snaps, snaps, { tol: 1e-9 }), []);
  assert.deepEqual(compare(golden.points_head, points.slice(0, 500), { tol: 1e-9 }), []);
  assert.ok(days.length > 0);
  assert.ok(Object.keys(latestRaw(files, "status_latest")).length > 0);
});

test("loadTables edge cases", () => {
  const trip = (id, pts) => ({ resMsg: { tripInfo: { tripStartTime: id, tripEndTime: "20250102000500", tripDrvTime: 3, tripIdleTime: 2, tripList: pts, tripStartCoord: { lat: 1, lon: 2 } } } });
  const files = {
    "raw/trips/v/a.json": trip("20250101235800", [
      { tripTime: "235800", lat: 28, lon: 77 }, { tripTime: "235900", lat: 28.001, lon: 77 }, { tripTime: "000100", lat: 28.002, lon: 77 }]),
    "raw/trips/v/a.meta.json": { ignored: true },
    "raw/snapshots/v/20250101T010203/status_latest.json": { resMsg: { time: "20250101010000", fuelLevel: 50, doorLock: true, dte: { value: 300 } } },
    "raw/snapshots/v/20250101T010203/status_latest.meta.json": {},
  };
  const { trips, points, snaps } = loadTables(files);
  assert.equal(trips.length, 1);
  assert.equal(trips[0].total_min, 5);
  assert.equal(trips[0].elapsed_min, 7);
  assert.equal(trips[0].has_route, 1);
  assert.deepEqual(points.map((p) => p.ts), ["2025-01-01T23:58:00", "2025-01-01T23:59:00", "2025-01-02T00:01:00"]);
  assert.equal(snaps[0].taken_at, "2025-01-01T01:02:03");
  assert.equal(snaps[0].door_lock, 1);
  assert.equal(snaps[0].odometer_km, null);
  assert.deepEqual(latestRaw(files, "nope"), {});
});

test("fmtInt / fmtFixed / fmtDate", () => {
  assert.equal(fmtInt(11365.4), "11,365");
  assert.equal(fmtInt(1234567.5), "1,234,568");
  assert.equal(fmtInt(2.5), "2");
  assert.equal(fmtInt(3.5), "4");
  assert.equal(fmtInt(-1234.6), "-1,235");
  assert.equal(fmtInt(999), "999");
  assert.equal(fmtFixed(0.125, 2), "0.12");
  assert.equal(fmtFixed(2.675, 2), "2.67"); // binary value is below the tie
  assert.equal(fmtFixed(1.005, 1), "1.0");
  assert.equal(fmtDate("2025-11-25", "%-d %B %Y"), "25 November 2025");
  assert.equal(fmtDate("2025-11-05T10:00:00", "%-d %B"), "5 November");
  assert.equal(fmtDate("2025-03-05", "%B"), "March");
});

test("median / quantile follow pandas", () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([4, 1, 3, 2]), 2.5);
  assert.equal(quantile([1, 2, 3, 4], 0.5), 2.5);
  assert.equal(quantile([1, 2, 3, 4], 0.25), 1.75);
  assert.equal(quantile([1, 2, 3, 4, null, NaN], 0.9), 3.7);
  assert.ok(Number.isNaN(median([])));
});

test("solve / inv / lstsq", () => {
  const A = [[2, 1], [1, 3]];
  const x = solve(A, [3, 5]);
  assert.ok(Math.abs(x[0] - 0.8) < 1e-12 && Math.abs(x[1] - 1.4) < 1e-12);
  const I = inv(A);
  assert.ok(Math.abs(I[0][0] - 0.6) < 1e-12 && Math.abs(I[0][1] + 0.2) < 1e-12);
  const X = [[1, 0], [1, 1], [1, 2], [1, 3]];
  const [a, b] = lstsq(X, [1, 3, 5, 7.5]);
  assert.ok(Math.abs(a - 0.9) < 1e-12 && Math.abs(b - 2.15) < 1e-12);
  assert.throws(() => solve([[1, 2], [2, 4]], [1, 2]));
});

test("groupBy / haversineKm", () => {
  const g = groupBy([1, 2, 3, 4], (v) => v % 2);
  assert.deepEqual([...g], [[1, [1, 3]], [0, [2, 4]]]);
  assert.ok(Math.abs(haversineKm(0, 0, 0, 1) - 111.19492664455873) < 1e-9);
});
