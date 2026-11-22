import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { compare } from "./parity.js";
import { root, rawDir, csvPath, readBook, refuelsFromCsv } from "./helpers.js";
import { loadTables } from "../src/tables.js";
import { fillsFromRefuels } from "../src/logs.js";
import { buildFuel } from "../src/fuel.js";
import { buildOverview } from "../src/insights.js";
import { buildPerformance, kmeans, jacobiEigen, mulberry32 } from "../src/performance.js";

const goldenPath = path.join(root, "tests", "golden", "performance.json");
const TODAY = "2026-10-25";

let cache;
function setup() {
  if (cache) return cache;
  assert.ok(fs.existsSync(rawDir), "data/raw missing");
  assert.ok(fs.existsSync(goldenPath), "tests/golden/performance.json missing");
  assert.ok(fs.existsSync(csvPath), "Sheet 1-Car Fuel.csv missing");
  const files = readBook(rawDir);
  const tables = loadTables(files);
  const odoNow = tables.snaps.filter((s) => s.odometer_km != null).at(-1).odometer_km;
  const fills = fillsFromRefuels(refuelsFromCsv(fs.readFileSync(csvPath, "utf8")));
  const fuel = buildFuel(tables, fills, odoNow, { source: "Sheet 1-Car Fuel.csv" });
  const delta = fuel.calibration.delta;
  buildOverview(tables, files, { today: TODAY, delta, fuel }); // sets from_place/to_place on trips
  const golden = JSON.parse(fs.readFileSync(goldenPath, "utf8"));
  const out = buildPerformance(tables, { today: TODAY, odoNow, delta, fuelModel: fuel.model });
  return (cache = { golden, out });
}

// Fix each PCA component's sign so its largest-|loading| entry is positive.
function normaliseOracle(g) {
  const feats = g.clusters.features;
  const flip = [0, 1].map((j) => {
    let big = 0;
    feats.forEach((f, i) => { if (Math.abs(g.clusters.loadings[f][j]) > Math.abs(g.clusters.loadings[feats[big]][j])) big = i; });
    return g.clusters.loadings[feats[big]][j] < 0 ? -1 : 1;
  });
  return {
    loadings: Object.fromEntries(feats.map((f) => [f, g.clusters.loadings[f].map((v, j) => v * flip[j])])),
    trips: g.trips.map((r) => ({ pc1: r.pc1 * flip[0], pc2: r.pc2 * flip[1] })),
  };
}

function adjustedRand(a, b) {
  const c2 = (n) => (n * (n - 1)) / 2;
  const tab = new Map(), ra = new Map(), rb = new Map();
  a.forEach((x, i) => {
    const k = `${x}|${b[i]}`;
    tab.set(k, (tab.get(k) ?? 0) + 1); ra.set(x, (ra.get(x) ?? 0) + 1); rb.set(b[i], (rb.get(b[i]) ?? 0) + 1);
  });
  const sum = (it) => [...it].reduce((s, v) => s + c2(v), 0);
  const idx = sum(tab.values()), sa = sum(ra.values()), sb = sum(rb.values());
  const exp = (sa * sb) / c2(a.length), max = (sa + sb) / 2;
  return max === exp ? 1 : (idx - exp) / (max - exp);
}

const havePrivateArchive = fs.existsSync(path.join(root, "data", "raw")) && fs.existsSync(path.join(root, "tests", "golden", "fuel.json")) && fs.existsSync(path.join(root, "Sheet 1-Car Fuel.csv"));

test("everything but the clustering matches the Python oracle (tol 1e-6)", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { golden, out } = setup();
  const ignore = ["generated_at", "clusters", "trips[].cluster", "trips[].pc1", "trips[].pc2", "bands_by_cluster"];
  assert.deepEqual(compare(golden, out, { tol: 1e-6, ignore }), []);
});

test("clusters agree with the oracle: partition, profiles, silhouette, PCA", { skip: !havePrivateArchive && "private archive not distributed" }, () => {
  const { golden, out } = setup();
  const ari = adjustedRand(golden.trips.map((r) => r.cluster), out.trips.map((r) => r.cluster));
  assert.ok(ari >= 0.99, `ARI ${ari}`);
  assert.deepEqual(out.clusters.profiles.map((p) => p.name), golden.clusters.profiles.map((p) => p.name));
  assert.deepEqual(out.clusters.features, golden.clusters.features);
  assert.equal(out.clusters.k, golden.clusters.k);
  for (const k of Object.keys(golden.clusters.silhouette)) {
    assert.ok(Math.abs(golden.clusters.silhouette[k] - out.clusters.silhouette[k]) <= 1e-3, `silhouette ${k}`);
  }
  const norm = normaliseOracle(golden);
  assert.deepEqual(compare(golden.clusters.explained_variance, out.clusters.explained_variance, { tol: 1e-6 }), []);
  assert.deepEqual(compare(norm.loadings, out.clusters.loadings, { tol: 1e-6 }), []);
  assert.deepEqual(compare(norm.trips, out.trips.map((r) => ({ pc1: r.pc1, pc2: r.pc2 })), { tol: 1e-6 }), []);
  if (ari === 1) {
    assert.deepEqual(compare(golden.clusters.profiles, out.clusters.profiles, { tol: 1e-6 }), []);
    assert.deepEqual(compare(golden.bands_by_cluster, out.bands_by_cluster, { tol: 1e-6 }), []);
    assert.deepEqual(golden.trips.map((r) => r.cluster), out.trips.map((r) => r.cluster));
  }
});

test("kmeans separates two obvious blobs deterministically; jacobi recovers a known spectrum", () => {
  const rnd = mulberry32(7);
  const X = Array.from({ length: 60 }, (_, i) => [(i < 30 ? 0 : 10) + rnd(), rnd()]);
  const l = kmeans(X, 2, 5);
  assert.equal(new Set(l.slice(0, 30)).size, 1);
  assert.equal(new Set(l.slice(30)).size, 1);
  assert.notEqual(l[0], l[30]);
  assert.deepEqual(kmeans(X, 2, 5), l);
  const { values } = jacobiEigen([[2, 1, 0], [1, 2, 0], [0, 0, 5]]);
  assert.ok(values.every((v, i) => Math.abs(v - [5, 3, 1][i]) < 1e-12));
});
