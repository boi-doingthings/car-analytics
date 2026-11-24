import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../../web/common.js', import.meta.url), 'utf8');
const now = Date.parse('2026-11-22T12:00:00Z');
const fresh = new Date(now - 60_000).toISOString();
const stale = new Date(now - 2 * 86400_000).toISOString();
class FixedDate extends Date {
  constructor(...args) { super(...(args.length ? args : [now])); }
  static now() { return now; }
}
function element() {
  const classes = new Set(), listeners = new Map();
  return {
    textContent: '', innerHTML: '', disabled: false, hidden: false, listeners,
    classList: {
      add(name) { classes.add(name); },
      toggle(name, on) { if (on) classes.add(name); else classes.delete(name); },
      contains(name) { return classes.has(name); },
    },
    addEventListener(name, callback) {
      if (!listeners.has(name)) listeners.set(name, []);
      listeners.get(name).push(callback);
    },
    // Dispatch directly so tests also exercise the controller's duplicate-click guard.
    async click() { await Promise.all((listeners.get('click') ?? []).map((callback) => callback())); },
  };
}
function harness(responses, { inApp = true } = {}) {
  const queue = [...responses], calls = [], timers = new Map();
  const button = element(), label = element(), main = element(), root = element();
  let timerID = 0, reloads = 0;
  const context = vm.createContext({
    Date: FixedDate, console,
    window: {},
    document: {
      documentElement: root,
      querySelector(selector) { return ({ '#sync-label': label, '#sync-btn': button, main })[selector] ?? null; },
      querySelectorAll() { return []; },
    },
    location: { protocol: inApp ? 'i20:' : 'http:', reload() { reloads++; } },
    matchMedia() { return { matches: false }; },
    addEventListener() {},
    fetch: async (url, options = {}) => {
      calls.push({ url, method: options.method ?? 'GET' });
      assert.ok(queue.length, 'unexpected additional fetch');
      const response = queue.shift();
      if (response instanceof Error) throw response;
      if (response?.httpError) return { ok: false, status: 503 };
      return { ok: true, json: async () => response };
    },
    setTimeout(callback) { const id = ++timerID; timers.set(id, callback); return id; },
    clearTimeout(id) { timers.delete(id); },
  });
  vm.runInContext(source, context, { filename: 'web/common.js' });
  return {
    LB: context.window.LB, button, label, main, calls, timers,
    get reloads() { return reloads; },
    get remainingResponses() { return queue.length; },
    async tick() {
      assert.equal(timers.size, 1, 'only one polling timer may exist');
      const [id, callback] = timers.entries().next().value;
      timers.delete(id);
      await callback();
    },
  };
}
const idle = (extra = {}) => ({ running: false, error: null, issues: 0, ...extra });
const running = (extra = {}) => ({ running: true, step: 'analyse', error: null, ...extra });
const methods = (app) => app.calls.map((call) => call.method);

test('native page loads never auto-POST for missing or stale collection timestamps', async () => {
  for (const last_sync of [null, stale]) {
    const app = harness([idle({ last_sync, last_analysis: fresh, read_only: true })]);
    await app.LB.initSync();
    assert.deepEqual(methods(app), ['GET']);
    assert.equal(app.timers.size, 0);
    assert.equal(app.reloads, 0);
    assert.equal(app.button.disabled, false);
    assert.equal(app.button.textContent, 'Rebuild');
    assert.match(app.label.textContent, /Analysis just now/);
    assert.ok(app.label.textContent.includes(last_sync ? 'Collected 2 days ago' : 'No collection timestamp'));
    assert.ok(!app.label.textContent.includes('Synced'), 'analysis must not imply a new vehicle collection');
  }
});

test('explicit native refresh issues one POST and one terminal reload, then remains settled', async () => {
  const app = harness([
    idle({ last_sync: null, last_analysis: stale, read_only: true }),
    running({ read_only: true }), running({ read_only: true }),
    idle({ last_sync: null, last_analysis: fresh, read_only: true }),
  ]);
  await app.LB.initSync();
  await Promise.all([app.button.click(), app.button.click()]);
  assert.deepEqual(methods(app), ['GET', 'POST']);
  assert.equal(app.button.disabled, true);
  await app.tick();
  await app.tick();
  assert.deepEqual(methods(app), ['GET', 'POST', 'GET', 'GET']);
  assert.equal(app.reloads, 1);
  assert.equal(app.timers.size, 0);
  await app.button.click();
  assert.equal(app.reloads, 1);
  assert.equal(app.calls.length, 4);
  const reloadedPage = harness([idle({ last_sync: null, last_analysis: fresh, read_only: true })]);
  await reloadedPage.LB.initSync();
  assert.deepEqual(methods(reloadedPage), ['GET'], 'the reload cannot restart the read-only rebuild');
  assert.equal(reloadedPage.timers.size, 0);
});

test('a native run already in progress is observed without starting a second run', async () => {
  const app = harness([running(), idle({ last_analysis: fresh, last_sync: stale })]);
  await app.LB.initSync();
  assert.deepEqual(methods(app), ['GET']);
  await app.tick();
  assert.deepEqual(methods(app), ['GET', 'GET']);
  assert.equal(app.reloads, 1);
  assert.equal(app.timers.size, 0);
});

test('duplicate initialization and missing-data fallback share one handler and polling controller', async () => {
  const app = harness([idle({ last_sync: null }), running(), idle({ last_analysis: fresh })]);
  const initialized = app.LB.initSync();
  app.LB.fail('synthetic load failure');
  await Promise.all([initialized, app.LB.initSync()]);
  assert.deepEqual(methods(app), ['GET']);
  assert.equal(app.button.listeners.get('click').length, 1);
  assert.ok(!app.main.innerHTML.includes('starts by itself'));
  await app.button.click();
  await app.tick();
  assert.deepEqual(methods(app), ['GET', 'POST', 'GET']);
  assert.equal(app.reloads, 1);
  assert.equal(app.timers.size, 0);
});

test('terminal server failures stop polling and leave an explicit retry available', async () => {
  const app = harness([idle(), running(), idle({ error: 'Archive could not be read' })]);
  await app.LB.initSync();
  await app.button.click();
  await app.tick();
  assert.equal(app.reloads, 0);
  assert.equal(app.timers.size, 0);
  assert.equal(app.button.disabled, false);
  assert.equal(app.label.textContent, 'Archive could not be read');
  assert.equal(app.label.classList.contains('err'), true);
  assert.deepEqual(methods(app), ['GET', 'POST', 'GET']);
});

test('poll network, HTTP and malformed-status errors settle without runaway timers and can retry', async () => {
  for (const failure of [new Error('offline'), { httpError: true }, { not_running: true }]) {
    const app = harness([idle(), running(), failure, running(), idle({ last_analysis: fresh })]);
    await app.LB.initSync();
    await app.button.click();
    await app.tick();
    assert.equal(app.reloads, 0);
    assert.equal(app.timers.size, 0);
    assert.equal(app.button.disabled, false);
    assert.match(app.label.textContent, /Couldn’t read sync status/);
    await app.button.click();
    await app.tick();
    assert.deepEqual(methods(app), ['GET', 'POST', 'GET', 'POST', 'GET']);
    assert.equal(app.reloads, 1);
    assert.equal(app.timers.size, 0);
  }
});

test('POST and initial GET failures are caught, settle, and never trigger an automatic retry', async () => {
  const postFailure = harness([idle(), new Error('POST unavailable')]);
  await postFailure.LB.initSync();
  await postFailure.button.click();
  assert.deepEqual(methods(postFailure), ['GET', 'POST']);
  assert.equal(postFailure.reloads, 0);
  assert.equal(postFailure.timers.size, 0);
  assert.equal(postFailure.button.disabled, false);
  const initialFailure = harness([new Error('GET unavailable'), idle({ last_analysis: fresh })]);
  await initialFailure.LB.initSync();
  assert.deepEqual(methods(initialFailure), ['GET']);
  assert.equal(initialFailure.timers.size, 0);
  assert.equal(initialFailure.button.disabled, false);
  await initialFailure.button.click();
  assert.deepEqual(methods(initialFailure), ['GET', 'POST']);
  assert.equal(initialFailure.reloads, 1);
});

test('Mac viewer keeps its stale-or-missing timestamp automatic rebuild behaviour', async () => {
  for (const last_sync of [stale, null]) {
    const app = harness([idle({ last_sync }), running(), idle({ last_sync: fresh })], { inApp: false });
    await app.LB.initSync();
    assert.deepEqual(methods(app), ['GET', 'POST']);
    await app.tick();
    assert.equal(app.reloads, 1);
    assert.equal(app.timers.size, 0);
    assert.match(app.label.textContent, /Synced just now/);
    const reloadedPage = harness([idle({ last_sync: fresh })], { inApp: false });
    await reloadedPage.LB.initSync();
    assert.deepEqual(methods(reloadedPage), ['GET']);
    assert.equal(reloadedPage.reloads, 0);
  }
});


test('Mac static dashboard retains its data-age fallback when no sync endpoint exists', async () => {
  const app = harness([new Error('No endpoint')], { inApp: false });
  await app.LB.initSync(fresh);
  assert.equal(app.button.hidden, true);
  assert.equal(app.label.textContent, 'Data from just now');
  assert.deepEqual(methods(app), ['GET']);
  assert.equal(app.timers.size, 0);
  assert.equal(app.reloads, 0);
});

test('clicks while the initial status request is pending cannot race a second sync controller', async () => {
  let resolveInitial;
  const pending = new Promise((resolve) => { resolveInitial = resolve; });
  const app = harness([pending, running(), idle({ last_analysis: fresh })]);
  const initialized = app.LB.initSync();
  assert.equal(app.button.disabled, true);
  await app.button.click();
  assert.deepEqual(methods(app), ['GET']);
  resolveInitial(idle());
  await initialized;
  assert.equal(app.button.disabled, false);
  await app.button.click();
  await app.tick();
  assert.deepEqual(methods(app), ['GET', 'POST', 'GET']);
  assert.equal(app.reloads, 1);
  assert.equal(app.timers.size, 0);
});


test('native metadata checks with unchanged generations settle without reloading', async () => {
  for (const generation of ['generation-A', null]) {
    const app = harness([
      running({ step: 'check', analysis_generation: generation, last_analysis: generation ? fresh : null }),
      idle({ analysis_generation: generation, last_analysis: generation ? fresh : null }),
    ]);
    await app.LB.initSync();
    assert.equal(app.label.textContent, 'Checking archive…');
    await app.tick();
    assert.deepEqual(methods(app), ['GET', 'GET']);
    assert.equal(app.reloads, 0);
    assert.equal(app.timers.size, 0);
    assert.equal(app.button.disabled, false);
    if (generation === null) assert.match(app.label.textContent, /No analysis yet/);
  }
});

test('generation changes reload native pages once even when analysis timestamps are equal', async () => {
  const app = harness([
    running({ step: 'check', analysis_generation: 'generation-A', last_analysis: fresh }),
    idle({ analysis_generation: 'generation-B', last_analysis: fresh }),
  ]);
  await app.LB.initSync();
  await app.tick();
  assert.equal(app.reloads, 1);
  assert.equal(app.timers.size, 0);
  assert.deepEqual(methods(app), ['GET', 'GET']);
});

test('explicit refresh reloads a newly published generation and suppresses unchanged known generations', async () => {
  for (const terminal of ['generation-A', 'generation-B']) {
    const app = harness([
      idle({ analysis_generation: 'generation-A', last_analysis: fresh }),
      running({ analysis_generation: 'generation-A', last_analysis: fresh }),
      idle({ analysis_generation: terminal, last_analysis: fresh }),
    ]);
    await app.LB.initSync();
    await app.button.click();
    await app.tick();
    assert.deepEqual(methods(app), ['GET', 'POST', 'GET']);
    assert.equal(app.reloads, terminal === 'generation-A' ? 0 : 1);
    assert.equal(app.timers.size, 0);
    assert.equal(app.button.disabled, terminal !== 'generation-A');
  }
});

test('legacy explicit refresh without generation metadata preserves its successful reload fallback', async () => {
  const app = harness([idle({ last_analysis: fresh }), running({ last_analysis: fresh }), idle({ last_analysis: fresh })]);
  await app.LB.initSync();
  await app.button.click();
  await app.tick();
  assert.deepEqual(methods(app), ['GET', 'POST', 'GET']);
  assert.equal(app.reloads, 1);
  assert.equal(app.timers.size, 0);
});

test('a first generation observed during an existing run can suppress a no-op completion', async () => {
  const app = harness([
    running({ step: 'check' }),
    running({ step: 'check', analysis_generation: 'generation-A' }),
    idle({ analysis_generation: 'generation-A' }),
  ]);
  await app.LB.initSync();
  await app.tick();
  await app.tick();
  assert.deepEqual(methods(app), ['GET', 'GET', 'GET']);
  assert.equal(app.reloads, 0);
  assert.equal(app.timers.size, 0);
  assert.equal(app.button.disabled, false);
});
