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


test('filename identity rejects plausible duplicate records without changing canonical analytics', () => {
  const files = book();
  const canonicalRefuel = Object.keys(files).find((key) => key.startsWith('log/refuels/'));
  const canonicalService = Object.keys(files).find((key) => key.startsWith('log/services/'));
  const maintenanceID = '00000000-0000-4000-8000-000000000090';
  files[`log/maintenance/${maintenanceID}.json`] = {
    schema: 1, id: maintenanceID, entered_at: '2026-10-05T08:00:00+05:30', date: '2026-10-05',
    category: 'wash', cost: 100, note: 'Synthetic maintenance', reminder: '2026-10-10',
  };
  const baseline = runAll(files, options);
  const canonicalContents = JSON.stringify(files[canonicalRefuel]);
  const rogueRefuelID = '00000000-0000-4000-8000-000000000091';
  const missingRefuelID = '00000000-0000-4000-8000-000000000092';
  const rogueServiceID = '00000000-0000-4000-8000-000000000093';
  const rogueMaintenanceID = '00000000-0000-4000-8000-000000000094';
  // Every extra record looks otherwise valid. A copied embedded ID must not double count its original.
  files[`log/refuels/${rogueRefuelID}.json`] = { ...files[canonicalRefuel], litres: 99, amount: 9900 };
  files[`log/refuels/${missingRefuelID}.json`] = { ...files[canonicalRefuel] };
  delete files[`log/refuels/${missingRefuelID}.json`].id;
  files[`log/services/${rogueServiceID}.json`] = { ...files[canonicalService], total: 90000 };
  files[`log/maintenance/${rogueMaintenanceID}.json`] = { ...files[`log/maintenance/${maintenanceID}.json`], cost: 90000 };
  const out = runAll(files, options);
  assert.deepEqual(out.errors, []);
  assert.deepEqual(out.fuel, baseline.fuel);
  assert.deepEqual(out.data.services, baseline.data.services);
  assert.deepEqual(out.data.running_cost, baseline.data.running_cost);
  assert.deepEqual(out.data.reminders, baseline.data.reminders);
  assert.equal(JSON.stringify(files[canonicalRefuel]), canonicalContents, 'canonical source records remain unchanged');
  assert.equal(out.warnings.length, 4);
  for (const id of [rogueRefuelID, missingRefuelID, rogueServiceID, rogueMaintenanceID]) {
    assert.ok(out.warnings.some((warning) => warning.startsWith(`skipping entry ${id}:`)),
      'warnings use the canonical filename stem for native-reader deduplication');
  }
  assert.ok(out.warnings.find((warning) => warning.startsWith(`skipping entry ${rogueRefuelID}:`))
    .includes(files[canonicalRefuel].id), 'mismatched embedded identity remains available for diagnosis');
  assert.match(out.warnings.find((warning) => warning.startsWith(`skipping entry ${missingRefuelID}:`)), /missing/);
});

test('malformed embedded identity is diagnosed by filename while conflict names remain excluded', () => {
  const files = book();
  const filenameID = '00000000-0000-4000-8000-000000000095';
  files[`log/refuels/${filenameID}.json`] = { schema: 1, id: 'hand-edited' };
  files[`log/refuels/${filenameID} 2.json`] = { schema: 1, id: 'conflict-copy' };
  files['log/refuels/------------------------------------.json'] = { schema: 1, id: '------------------------------------', date: '2026-10-05' };
  const out = runAll(files, options);
  assert.deepEqual(out.errors, []);
  assert.equal(out.warnings.length, 1);
  assert.ok(out.warnings[0].startsWith(`skipping entry ${filenameID}:`));
  assert.match(out.warnings[0], /hand-edited/);
  assert.equal(out.fuel.totals.fills, 3);
});


test('non-string identity objects cannot poison otherwise valid refuel analytics', () => {
  const files = book();
  const filenameID = '00000000-0000-4000-8000-000000000096';
  const original = Object.keys(files).find((key) => key.startsWith('log/refuels/'));
  // JSON can shadow toString with a scalar; diagnostics must not try to invoke it.
  files[`log/refuels/${filenameID}.json`] = { ...files[original], id: { toString: 'not callable' } };
  const out = runAll(files, options);
  assert.deepEqual(out.errors, []);
  assert.equal(out.fuel.totals.fills, 3);
  assert.equal(out.warnings.length, 1);
  assert.ok(out.warnings[0].startsWith(`skipping entry ${filenameID}:`));
  assert.match(out.warnings[0], /invalid object/);
  assert.ok(!out.warnings[0].includes('not callable'), 'do not dump invalid object contents into diagnostics');
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
