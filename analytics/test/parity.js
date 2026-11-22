// Deep-compare helper for Python-oracle parity tests.
// compare(expected, actual, {ignore, tol}) -> list of "path: reason" mismatches (empty when equal).
// Paths look like `a.b[3].c`. `ignore` entries match a path exactly, or with array indices
// written as `[]` (e.g. `trips[].id`); an ignored path also ignores everything beneath it.
// Numbers match when |e - a| <= tol * max(1, |e|).

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

export function compare(expected, actual, { ignore = [], tol = 0 } = {}) {
  const skip = new Set(ignore);
  const out = [];
  const ignored = (path) => skip.has(path) || skip.has(path.replace(/\[\d+\]/g, "[]"));

  function walk(e, a, path) {
    if (path && ignored(path)) return;
    if (typeof e === "number" && typeof a === "number") {
      if (!(Math.abs(e - a) <= tol * Math.max(1, Math.abs(e))) && !(Number.isNaN(e) && Number.isNaN(a))) {
        out.push(`${path}: ${e} != ${a}`);
      }
    } else if (Array.isArray(e) && Array.isArray(a)) {
      if (e.length !== a.length) out.push(`${path}: length ${e.length} != ${a.length}`);
      for (let i = 0; i < Math.min(e.length, a.length); i++) walk(e[i], a[i], `${path}[${i}]`);
    } else if (isObj(e) && isObj(a)) {
      for (const k of Object.keys(e)) {
        const p = path ? `${path}.${k}` : k;
        if (ignored(p)) continue;
        if (!(k in a)) out.push(`${p}: missing`);
        else walk(e[k], a[k], p);
      }
      for (const k of Object.keys(a)) {
        const p = path ? `${path}.${k}` : k;
        if (!(k in e) && !ignored(p)) out.push(`${p}: unexpected`);
      }
    } else if (e !== a) {
      out.push(`${path || "(root)"}: ${e} != ${a}`);
    }
  }

  walk(expected, actual, "");
  return out;
}
