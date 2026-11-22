import { test } from "node:test";
import assert from "node:assert/strict";
import { compare } from "./parity.js";

test("compare flags numeric drift beyond tolerance", () => {
  assert.deepEqual(compare({a: 1.0}, {a: 1.0 + 1e-9}, {tol: 1e-6}), []);
  assert.deepEqual(compare({a: [1, 2]}, {a: [1, 3]}, {tol: 1e-6}), ["a[1]: 2 != 3"]);
  assert.deepEqual(compare({a: "x", g: 1}, {a: "y", g: 2}, {ignore: ["g"]}), ["a: x != y"]);
  assert.deepEqual(compare({a: null}, {}, {}), ["a: missing"]);
});
