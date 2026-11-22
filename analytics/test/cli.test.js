import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { runAll } from "../src/index.js";
import { root, rawDir, csvPath, readBook, refuelsFromCsv } from "./helpers.js";

const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "cli.mjs");
const TODAY = "2026-10-25";

const fixtureBook = path.join(root, "ios", "Tests", "Fixtures", "book");

/** A temp copy of the small committed fixture book (3 trips, 3 refuels, 1 service) plus noise the CLI must ignore. */
function makeBook() {
  const book = fs.mkdtempSync(path.join(os.tmpdir(), "i20book-"));
  fs.cpSync(fixtureBook, book, { recursive: true });
  fs.writeFileSync(path.join(book, "raw", ".DS_Store"), "x");
  fs.writeFileSync(path.join(book, "raw", "something.meta.json"), "{not json");
  return book;
}

/** path -> sha256 of every file and directory in the tree (names, sizes via content). */
function hashTree(dir) {
  const out = {};
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name), rel = path.relative(dir, p);
      if (e.isDirectory()) { out[rel + "/"] = ""; walk(p); }
      else out[rel] = crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex");
    }
  })(dir);
  return out;
}

const run = (book, out, ...extra) =>
  spawnSync(process.execPath, [cli, "--book", book, "--out", out, "--today", TODAY, ...extra], { encoding: "utf8" });
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "i20out-"));
const expected = (book) => {
  const files = {};
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".json") && !e.name.endsWith(".meta.json") && /^(raw|log)\//.test(path.relative(book, p)))
        files[path.relative(book, p).split(path.sep).join("/")] = JSON.parse(fs.readFileSync(p, "utf8"));
    }
  })(book);
  return JSON.parse(JSON.stringify(runAll(files, { today: TODAY, source: "refuel log" })));
};

test("success: writes data/fuel/performance matching runAll, and leaves the book untouched", () => {
  const book = makeBook(), out = tmp();
  const before = hashTree(book);
  const r = run(book, out);
  assert.equal(r.status, 0, r.stderr);
  const summary = JSON.parse(r.stdout.trim().split("\n").pop());
  assert.deepEqual(summary.errors, []);
  assert.equal(summary.issues, 0);
  assert.equal(summary.files, Object.keys(before).filter((k) => /^(raw|log)\/.*\.json$/.test(k) && !k.endsWith(".meta.json")).length);
  assert.deepEqual(fs.readdirSync(out).sort(), ["data.json", "fuel.json", "performance.json"]);
  const want = expected(book);
  const nowless = (o) => ({ ...o, generated_at: undefined }); // build time differs by a second
  for (const n of ["data", "fuel", "performance"]) assert.deepEqual(nowless(JSON.parse(fs.readFileSync(path.join(out, `${n}.json`), "utf8"))), nowless(want[n]), n);
  assert.deepEqual(hashTree(book), before);
});

test("no refuels: fuel.json is removed, others written", () => {
  const book = makeBook(), out = tmp();
  fs.rmSync(path.join(book, "log"), { recursive: true });
  fs.writeFileSync(path.join(out, "fuel.json"), "{}");
  const r = run(book, out);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(fs.readdirSync(out).sort(), ["data.json", "performance.json"]);
});

test("an unparseable raw file is skipped and counted as an issue", () => {
  const book = makeBook(), out = tmp();
  fs.writeFileSync(path.join(book, "raw", "broken.json"), "{oops");
  const before = hashTree(book);
  const r = run(book, out);
  assert.equal(r.status, 0, r.stderr);
  const summary = JSON.parse(r.stdout.trim().split("\n").pop());
  assert.equal(summary.issues, 1);
  assert.deepEqual(hashTree(book), before);
});

test("iCloud placeholder: exit 3, one-line message, nothing written", () => {
  const book = makeBook(), out = tmp();
  fs.writeFileSync(path.join(book, "raw", ".20261020.json.icloud"), "");
  fs.writeFileSync(path.join(book, "log", "refuels", ".abc.json.icloud"), "");
  const before = hashTree(book);
  const r = run(book, out);
  assert.equal(r.status, 3);
  assert.equal(r.stdout.trim(), "2 files still downloading from iCloud — sync again shortly");
  assert.deepEqual(fs.readdirSync(out), []);
  assert.deepEqual(hashTree(book), before);
});

test("missing book folder: exit 2, nothing written", () => {
  const out = tmp();
  const r = run(path.join(os.tmpdir(), "i20book-does-not-exist"), out);
  assert.equal(r.status, 2);
  assert.deepEqual(fs.readdirSync(out), []);
});

test("--out inside or equal to the book: exit 2, book untouched", () => {
  const book = makeBook();
  const before = hashTree(book);
  for (const out of [book, path.join(book, "derived"), path.join(book, "raw", "..", "x")]) {
    const r = run(book, out);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /--out must not be/);
  }
  assert.deepEqual(hashTree(book), before);
});

test("a folder with neither raw/ nor log/: exit 2", () => {
  const book = fs.mkdtempSync(path.join(os.tmpdir(), "i20book-"));
  const out = tmp();
  assert.equal(run(book, out).status, 2);
  assert.deepEqual(fs.readdirSync(out), []);
});

test("symlinked files are skipped", () => {
  const book = makeBook(), out = tmp();
  const [first] = fs.readdirSync(path.join(book, "log", "refuels"));
  fs.symlinkSync(path.join(book, "log", "refuels", first), path.join(book, "log", "refuels", "link.json"));
  const r = run(book, out);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout.trim()).files, 20);
});

// Optional: the real archive + CSV through the CLI. Skips when they are not on this machine.
test("real archive via the CLI matches runAll", { skip: !(fs.existsSync(rawDir) && fs.existsSync(csvPath)) && "data/raw or CSV missing" }, () => {
  const book = fs.mkdtempSync(path.join(os.tmpdir(), "i20book-")), out = tmp();
  fs.cpSync(rawDir, path.join(book, "raw"), { recursive: true });
  fs.mkdirSync(path.join(book, "log", "refuels"), { recursive: true });
  const entries = refuelsFromCsv(fs.readFileSync(csvPath, "utf8"));
  for (const e of entries) fs.writeFileSync(path.join(book, "log", "refuels", `${e.id}.json`), JSON.stringify(e));
  const r = run(book, out);
  assert.equal(r.status, 0, r.stderr);
  const files = readBook(rawDir);
  entries.forEach((e) => { files[`log/refuels/${e.id}.json`] = e; });
  const want = JSON.parse(JSON.stringify(runAll(files, { today: TODAY, source: "refuel log" })));
  const strip = (o) => ({ ...o, generated_at: undefined });
  assert.deepEqual(strip(JSON.parse(fs.readFileSync(path.join(out, "data.json"), "utf8"))), strip(want.data));
});
