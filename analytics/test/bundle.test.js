import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { compare } from "./parity.js";
import { root, rawDir, csvPath, readBook, refuelsFromCsv } from "./helpers.js";
import { buildBundle } from "../build.mjs";

const golden = (n) => path.join(root, "tests", "golden", `${n}.json`);
const TODAY = "2026-10-25";

async function loadBundle() {
  const file = await buildBundle();
  const ctx = vm.createContext({}); // empty: no console, DOM, fetch or Node APIs
  vm.runInContext(fs.readFileSync(file, "utf8"), ctx);
  return ctx;
}

function booksFiles() {
  const files = readBook(rawDir);
  refuelsFromCsv(fs.readFileSync(csvPath, "utf8")).forEach((e) => { files[`log/refuels/${e.id}.json`] = e; });
  const [visit] = JSON.parse(fs.readFileSync(path.join(root, "service_log.json"), "utf8")).services;
  files["log/services/00000000-0000-4000-8000-0000000000aa.json"] = { schema: 1, id: "00000000-0000-4000-8000-0000000000aa", entered_at: "2026-10-25T00:00:00+05:30", photos: [], ...visit };
  return files;
}

// Services in the app carry id/entered_at/photos and `resets: []`; the Python oracle's raw log entries do not.
const bare = (data) => ({
  ...data,
  services: data.services.map(({ id, entered_at, photos, ...s }) => ({
    ...s, parts: s.parts.map(({ resets, ...p }) => (resets.length ? { ...p, resets } : p)),
  })),
});

const havePrivateArchive = fs.existsSync(path.join(root, "data", "raw")) && fs.existsSync(path.join(root, "tests", "golden", "fuel.json")) && fs.existsSync(path.join(root, "Sheet 1-Car Fuel.csv"));

test("bundle runs in an empty vm context and matches all three goldens in < 10 s", { skip: !havePrivateArchive && "private archive not distributed" }, async () => {
  for (const p of [rawDir, csvPath, golden("data"), golden("fuel"), golden("performance")]) assert.ok(fs.existsSync(p), `${p} missing`);
  const ctx = await loadBundle();
  assert.equal(typeof ctx.I20Analytics.runAll, "function");
  const files = booksFiles();
  const t0 = Date.now();
  const out = ctx.I20Analytics.runAll(files, { today: TODAY, source: "Sheet 1-Car Fuel.csv" });
  assert.ok(Date.now() - t0 < 10000, `took ${Date.now() - t0} ms`);
  assert.equal(JSON.stringify(out.errors), "[]");
  const g = (n) => JSON.parse(fs.readFileSync(golden(n), "utf8"));
  // Objects come from another realm; round-trip so deepEqual prototypes match.
  const plain = JSON.parse(JSON.stringify(out));

  assert.deepEqual(compare(g("data"), bare(plain.data), { ignore: ["generated_at", "running_cost", "reminders"], tol: 1e-6 }), []);
  assert.deepEqual(compare(g("fuel"), plain.fuel, { tol: 1e-6 }), []);
  const gp = g("performance");
  const ignore = ["generated_at", "clusters", "trips[].cluster", "trips[].pc1", "trips[].pc2", "bands_by_cluster"];
  assert.deepEqual(compare(gp, plain.performance, { tol: 1e-6, ignore }), []);
  // Cluster labels may be permuted: require the same partition.
  const map = new Map();
  gp.trips.forEach((r, i) => {
    const got = plain.performance.trips[i].cluster;
    if (!map.has(r.cluster)) map.set(r.cluster, got);
    assert.equal(map.get(r.cluster), got, `trip ${i} cluster`);
  });
  assert.equal(plain.performance.clusters.k, gp.clusters.k);
});

test("runAll does not throw when pages fail: null outputs plus errors", async () => {
  const ctx = await loadBundle();
  const out = ctx.I20Analytics.runAll({}, { today: TODAY });
  assert.ok(out.errors.length > 0);
  assert.equal(out.performance, null);
  const bad = ctx.I20Analytics.runAll({ "raw/trips/v/x.json": null }, { today: TODAY });
  assert.ok(bad.errors.length > 0);
});

test("runAll without refuels returns fuel null but still builds the overview", { skip: !havePrivateArchive && "private archive not distributed" }, async () => {
  const ctx = await loadBundle();
  const files = booksFiles();
  for (const k of Object.keys(files)) if (k.startsWith("log/refuels/")) delete files[k];
  const out = ctx.I20Analytics.runAll(files, { today: TODAY });
  assert.equal(out.fuel, null);
  assert.ok(out.data);
  assert.ok(out.performance);
});

test("entries with schema > 1 are skipped with a warning, not a crash", { skip: !havePrivateArchive && "private archive not distributed" }, async () => {
  const ctx = await loadBundle();
  const files = booksFiles();
  const first = Object.keys(files).find((k) => k.startsWith("log/refuels/"));
  files["log/refuels/00000000-0000-4000-8000-0000000000ff.json"] = { ...files[first], id: "future", schema: 2 };
  const out = ctx.I20Analytics.runAll(files, { today: TODAY });
  assert.equal(JSON.stringify(out.errors), "[]");
  assert.equal(out.warnings.length, 1);
});

test("odd file names are ignored and a malformed entry is skipped without blanking the fuel page", { skip: !havePrivateArchive && "private archive not distributed" }, async () => {
  const ctx = await loadBundle();
  const files = booksFiles();
  const first = Object.keys(files).find((k) => k.startsWith("log/refuels/"));
  const base = JSON.stringify(runAllLite(ctx, files));
  files["log/refuels/00000000-0000-4000-8000-000000000000 2.json"] = { ...files[first] }; // iCloud conflict copy
  files["log/refuels/notes.json"] = { oops: true };
  files["log/refuels/00000000-0000-4000-8000-0000000000ee.json"] = { id: "hand-edited" }; // no date
  const out = ctx.I20Analytics.runAll(files, { today: TODAY });
  assert.equal(JSON.stringify(out.errors), "[]");
  assert.ok(out.fuel);
  assert.equal(out.warnings.length, 1);
  assert.match(out.warnings[0], /hand-edited/);
  assert.equal(JSON.stringify(out.fuel.totals.fills), base);
});

const runAllLite = (ctx, files) => ctx.I20Analytics.runAll(files, { today: TODAY }).fuel.totals.fills;
