// Mac viewer: read-only run of the shared analytics over the iCloud book folder.
//   node analytics/cli.mjs --book <dir> --out <dir> [--today YYYY-MM-DD]
// Exit 0 ok (page errors are reported in the summary), 2 book unreadable, 3 files still downloading (nothing written).
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";
import { runAll } from "./src/index.js";

const istDay = (d = new Date()) => new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata" }).format(d);

/** Every raw/** and log/** *.json (no *.meta.json) as book-relative paths, plus iCloud placeholders for such files. */
function scan(book) {
  const paths = [], placeholders = [];
  let found = false;
  const walk = (dir, rel) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { if (e.code === "ENOENT") return; throw e; }
    found = true;
    for (const e of entries) {
      if (e.isSymbolicLink()) continue; // like Book.allFiles: links are not archive files
      const r = `${rel}/${e.name}`;
      if (e.isDirectory()) { walk(path.join(dir, e.name), r); continue; }
      const m = /^\.(.+)\.icloud$/.exec(e.name);
      const name = m ? m[1] : e.name;
      if (!name.endsWith(".json") || name.endsWith(".meta.json")) continue;
      if (m) placeholders.push(`${rel}/${name}`); else paths.push(r);
    }
  };
  walk(path.join(book, "raw"), "raw");
  walk(path.join(book, "log"), "log");
  if (!found) throw new Error("neither raw/ nor log/ in the book");
  return { paths: paths.sort(), placeholders };
}

function writeAtomic(file, text) {
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

export function main(argv) {
  const { values } = parseArgs({ args: argv, options: { book: { type: "string" }, out: { type: "string" }, today: { type: "string" } } });
  if (!values.book || !values.out) { console.error("usage: cli.mjs --book <dir> --out <dir> [--today YYYY-MM-DD]"); return 2; }
  const rel = path.relative(path.resolve(values.book), path.resolve(values.out));
  if (!rel.startsWith("..") && !path.isAbsolute(rel)) { console.error("--out must not be the book folder or inside it"); return 2; }
  let scanned;
  try {
    if (!fs.statSync(values.book).isDirectory()) throw new Error("not a directory");
    scanned = scan(values.book);
  } catch { console.error("can't read the book folder"); return 2; }
  const { paths, placeholders } = scanned;
  if (placeholders.length) {
    const n = placeholders.length;
    console.log(`${n} file${n === 1 ? "" : "s"} still downloading from iCloud — sync again shortly`);
    return 3;
  }

  const files = {}, issues = [];
  for (const p of paths) {
    try { files[p] = JSON.parse(fs.readFileSync(path.join(values.book, p), "utf8")); }
    catch (e) { issues.push(`${p}: ${e instanceof SyntaxError ? "not valid JSON" : "couldn't be read"}, left out`); }
  }
  const out = runAll(files, { today: values.today || istDay(), source: "refuel log" });
  const errors = out.errors.map((e) => `${e.page}: ${e.message}`);

  fs.mkdirSync(values.out, { recursive: true });
  for (const [name, v] of [["data", out.data], ["performance", out.performance]]) {
    if (v) writeAtomic(path.join(values.out, `${name}.json`), JSON.stringify(v));
  }
  const fuelFile = path.join(values.out, "fuel.json");
  if (out.fuel) writeAtomic(fuelFile, JSON.stringify(out.fuel)); else fs.rmSync(fuelFile, { force: true });

  const all = [...issues, ...errors, ...out.warnings];
  console.log(JSON.stringify({ files: paths.length, errors, warnings: out.warnings, issues: all.length }));
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exitCode = main(process.argv.slice(2));
