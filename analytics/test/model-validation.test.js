import test from 'node:test';
import assert from 'node:assert/strict';
import { fitModel, PRIOR } from '../src/fuel.js';

const date = (offset) => new Date(Date.UTC(2026, 0, 1 + offset)).toISOString().slice(0, 10);
function intervals(count = 8) {
  return Array.from({ length: count }, (_, i) => {
    const city = 80 + 14 * i, highway = 20 + (37 * i) % 80, idle = 0.2 + (i % 3) * 0.4;
    return {
      from: date(i * 7), to: date((i + 1) * 7), city_km: city, hwy_km: highway, idle_h: idle,
      km: city + highway, litres: city / 100 * 8.3 + highway / 100 * 5.2 + idle * 0.85 + (i % 2 ? 0.15 : -0.15),
      status: 'ok',
    };
  });
}
const mean = (values) => values.reduce((sum, value) => sum + value, 0) / values.length;

// Perturbing a test response must not change that fold's hyperparameters or prediction.
// Requiring the full-data sigma to change makes this catch the previous global-tuning leak.
test('LOO refits noise inside each fold without seeing the held-out litres', () => {
  const input = intervals();
  const before = fitModel(input);
  const changed = input.map((row, i) => i === input.length - 1 ? { ...row, litres: row.litres + 80 } : row);
  const after = fitModel(changed);
  assert.notEqual(before.sigma_l, after.sigma_l, 'adversarial test response changes full-data noise');
  const a = before.validation.loo.predictions.at(-1), b = after.validation.loo.predictions.at(-1);
  assert.equal(a.sigma_l, b.sigma_l);
  assert.equal(a.predicted_l, b.predicted_l);
  assert.equal(a.baseline_l, b.baseline_l);
  assert.equal(b.actual_l - a.actual_l, 80);
  assert.equal(before.loo_mae, before.validation.loo.model_mae_l);
  assert.equal(before.naive_loo_mae, before.validation.loo.baseline_mae_l);
  assert.equal(before.validation.loo.n_predictions, input.length);
  assert.ok(before.validation.loo.predictions.every((row) => row.train_intervals === input.length - 1));
});

test('chronological expanding windows are invariant to future responses and operating mix', () => {
  const input = intervals();
  const original = fitModel(input).validation.chronological;
  const changed = input.map((row, i) => i === input.length - 1
    ? { ...row, city_km: row.city_km * 4, km: row.city_km * 4 + row.hwy_km, litres: row.litres + 80 } : row);
  const modified = fitModel(changed).validation.chronological;
  assert.equal(original.n_predictions, input.length - original.min_train_intervals);
  assert.equal(original.min_train_intervals, 3);
  assert.deepEqual(modified.predictions.slice(0, -1), original.predictions.slice(0, -1));
  assert.deepEqual(original.predictions.map((row) => row.train_intervals), [3, 4, 5, 6, 7]);
  assert.equal(original.predictions[0].from, input[3].from);
  assert.deepEqual(fitModel([...input].reverse()).validation.chronological, original,
    'causal ordering uses interval dates, not caller input order');
});

test('each chronological prediction equals a model tuned only on its earlier training intervals', () => {
  const input = intervals(7);
  const result = fitModel(input).validation.chronological;
  for (const prediction of result.predictions) {
    const training = input.filter((row) => row.to <= prediction.from);
    const trained = fitModel(training);
    const target = input.find((row) => row.from === prediction.from && row.to === prediction.to);
    const expected = target.city_km / 100 * trained.coef.city_l100
      + target.hwy_km / 100 * trained.coef.hwy_l100 + target.idle_h * trained.coef.idle_lph;
    assert.equal(prediction.sigma_l, trained.sigma_l);
    assert.ok(Math.abs(prediction.predicted_l - expected) < 0.001,
      'serialized coefficient rounding accounts for less than a millilitre here');
  }
});

test('baseline predicts litres using pooled training L/km; bias is prediction minus actual', () => {
  const input = intervals(4).map((row, i) => {
    const km = [100, 200, 50, 80][i];
    return { ...row, city_km: km * 0.5, hwy_km: km * 0.5, idle_h: 0, km, litres: i === 3 ? 20 : km / 10 };
  });
  const result = fitModel(input).validation;
  assert.equal(result.units, 'litres');
  assert.equal(result.bias_definition, 'prediction_minus_actual');
  assert.equal(result.scope, 'conditional_on_precomputed_intervals');
  assert.equal(result.chronological.n_predictions, 1);
  const prediction = result.chronological.predictions[0];
  assert.equal(prediction.actual_l, 20);
  assert.equal(prediction.baseline_l, 8, '10 km/L on 80 km predicts 8 L, never 10 or 800');
  assert.equal(prediction.baseline_error_l, -12);
  assert.equal(result.chronological.baseline_mae_l, 12);
  assert.equal(result.chronological.baseline_bias_l, -12);
  assert.equal(prediction.error_l, prediction.predicted_l - prediction.actual_l);
});

test('insufficient samples report null metrics rather than zero error', () => {
  for (let count = 0; count <= 3; count++) {
    const result = fitModel(intervals(count)).validation;
    assert.equal(result.schema, 1);
    assert.equal(result.chronological.n_predictions, 0);
    for (const metric of ['model_mae_l', 'baseline_mae_l', 'model_bias_l', 'baseline_bias_l']) {
      assert.equal(result.chronological[metric], null);
      if (count < 2) assert.equal(result.loo[metric], null);
    }
    if (count < 2) assert.equal(result.loo.n_predictions, 0);
    assert.equal(result.chronological.insufficient_history_intervals, count);
  }
});

test('chronological validation excludes ambiguous same-day and malformed date intervals', () => {
  const input = intervals(7);
  const ambiguous = { ...input.at(-1), from: '2026-04-01', to: '2026-04-01' };
  const invalid = { ...input.at(-1), from: '2026-02-30', to: '2026-04-05' };
  const model = fitModel([...input, ambiguous, invalid]);
  assert.equal(model.n_intervals, input.length + 2, 'date exclusions are validation-only, not model eligibility changes');
  const forward = model.validation.chronological;
  assert.equal(forward.excluded_date_intervals, 2);
  assert.equal(forward.eligible_intervals, input.length);
  assert.deepEqual(forward.predictions, fitModel(input).validation.chronological.predictions);
});

test('overlapping intervals cannot contribute training responses not known at the test start', () => {
  const input = intervals(5);
  // The fourth interval finishes during the fifth rather than at its start.
  input[3] = { ...input[3], to: date(31) };
  const forward = fitModel(input).validation.chronological;
  const last = forward.predictions.find((row) => row.from === input[4].from);
  assert.ok(last);
  assert.equal(last.train_intervals, 3);
  const trained = fitModel(input.slice(0, 3));
  assert.equal(last.sigma_l, trained.sigma_l);
  const earlierOnly = fitModel([input[0], input[1], input[2], input[4]]).validation.chronological.predictions[0];
  assert.deepEqual(last, earlierOnly);
});

test('validation summaries reconcile all reported per-interval errors without rounding bias', () => {
  const input = intervals(7);
  input[2].litres += 3;
  const result = fitModel(input).validation;
  for (const report of [result.loo, result.chronological]) {
    assert.equal(report.n_predictions, report.predictions.length);
    assert.equal(report.baseline_n_predictions, report.predictions.length);
    assert.equal(report.model_mae_l, mean(report.predictions.map((row) => Math.abs(row.error_l))));
    assert.equal(report.model_bias_l, mean(report.predictions.map((row) => row.error_l)));
    assert.equal(report.baseline_mae_l, mean(report.predictions.map((row) => Math.abs(row.baseline_error_l))));
    assert.equal(report.baseline_bias_l, mean(report.predictions.map((row) => row.baseline_error_l)));
  }
});

// Independent dense Gaussian covariance calculation checks the reduced 3 × 3 evidence identity.
function denseLogEvidence(rows, sigma) {
  const prior = Object.values(PRIOR);
  const X = rows.map((row) => [row.city_km / 100, row.hwy_km / 100, row.idle_h]);
  const residual = rows.map((row, i) => row.litres - X[i].reduce((sum, x, j) => sum + x * prior[j][0], 0));
  const covariance = X.map((a, i) => X.map((b, j) =>
    a.reduce((sum, x, k) => sum + x * b[k] * prior[k][1] ** 2, 0) + (i === j ? sigma ** 2 : 0)));
  const lower = rows.map(() => Array(rows.length).fill(0));
  for (let i = 0; i < rows.length; i++) {
    for (let j = 0; j <= i; j++) {
      let value = covariance[i][j];
      for (let k = 0; k < j; k++) value -= lower[i][k] * lower[j][k];
      lower[i][j] = i === j ? Math.sqrt(value) : value / lower[j][j];
    }
  }
  const standardized = [];
  for (let i = 0; i < rows.length; i++) {
    standardized[i] = (residual[i] - lower[i].slice(0, i).reduce((sum, x, j) => sum + x * standardized[j], 0)) / lower[i][i];
  }
  return -0.5 * (standardized.reduce((sum, x) => sum + x * x, 0)
    + 2 * lower.reduce((sum, row, i) => sum + Math.log(row[i]), 0) + rows.length * Math.log(2 * Math.PI));
}

test('reduced evidence agrees with an independent dense covariance calculation', () => {
  const input = intervals(7);
  input[2].litres += 6;
  input[4].litres -= 2;
  const fitted = fitModel(input);
  const expected = fitted.evidence.sigma.map((sigma) => denseLogEvidence(input, sigma));
  const best = expected.indexOf(Math.max(...expected));
  assert.equal(fitted.sigma_l, fitted.evidence.sigma[best]);
  assert.ok(best > 0 && best < expected.length - 1, 'fixture exercises an interior noise optimum');
  for (let i = 0; i < expected.length; i++) {
    assert.ok(Math.abs(fitted.evidence.log_evidence[i] - expected[i]) <= 0.000501,
      'evidence values agree up to their documented 3-decimal serialization');
  }
});

test('ineligible intervals cannot tune coefficients, noise or validation predictions', () => {
  const input = intervals(6);
  const unusable = { ...input[2], litres: 100000, status: 'missing_fill' };
  const base = fitModel(input), withGap = fitModel([...input, unusable]);
  assert.deepEqual(withGap.coef, base.coef);
  assert.equal(withGap.sigma_l, base.sigma_l);
  assert.deepEqual(withGap.validation, base.validation);
});
