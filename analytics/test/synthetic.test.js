import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { runAll } from '../src/index.js';
import { buildBundle } from '../build.mjs';

const fixture = fileURLToPath(new URL('../../ios/Tests/Fixtures/book/', import.meta.url));
function book() {
  const files = {};
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.json') && !entry.name.endsWith('.meta.json'))
        files[path.relative(fixture, full).split(path.sep).join('/')] = JSON.parse(fs.readFileSync(full, 'utf8'));
    }
  }
  walk(fixture);
  return files;
}
const options = {today: '2026-10-05', source: 'synthetic fixture'};
const plain = v => JSON.parse(JSON.stringify(v));

test('synthetic archive builds all outputs with reconciled totals', () => {
  const out = runAll(book(), options);
  assert.deepEqual(out.errors, []);
  assert.deepEqual(out.warnings, []);
  assert.ok(out.data && out.fuel && out.performance);
  assert.equal(out.fuel.totals.fills, 3);
  assert.equal(out.performance.trips.length, 3);
  assert.equal(out.fuel.model.n_intervals, 1);
  assert.equal(out.fuel.model.loo_mae, null);
  const numeric = JSON.stringify(out);
  assert.ok(!numeric.includes('NaN'));
});

test('synthetic archive: no fills retains trip analytics and removes fuel estimate', () => {
  const files = book();
  for (const key of Object.keys(files)) if (key.startsWith('log/refuels/')) delete files[key];
  const out = runAll(files, options);
  assert.deepEqual(out.errors, []);
  assert.equal(out.fuel, null);
  assert.equal(out.performance.trips.length, 3);
  assert.ok(out.data);
});

test('synthetic archive: conflict copies cannot double count and future schemas warn', () => {
  const files = book();
  const name = Object.keys(files).find(k => k.startsWith('log/refuels/'));
  const baseline = runAll(files, options);
  files[name.replace('.json', ' 2.json')] = files[name];
  files['log/refuels/00000000-0000-4000-8000-000000000099.json'] = {...files[name], schema: 999};
  const out = runAll(files, options);
  assert.deepEqual(out.errors, []);
  assert.equal(out.fuel.totals.fills, baseline.fuel.totals.fills);
  assert.ok(out.warnings.some(w => /schema/i.test(w)));
});

test('bundled synthetic analytics agrees with source in a bare JavaScript context', async () => {
  const file = await buildBundle();
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync(file, 'utf8'), context);
  const source = plain(runAll(book(), options));
  const bundled = plain(context.I20Analytics.runAll(book(), options));
  // Wall-clock publication timestamps are not analytical results.
  for (const page of ['data', 'fuel', 'performance']) {
    if (source[page]) delete source[page].generated_at;
    if (bundled[page]) delete bundled[page].generated_at;
  }
  assert.deepEqual(bundled, source);
});
