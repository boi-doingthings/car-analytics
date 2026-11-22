/* Shared by every page: palette, formatting, chart/map helpers, header sync control. Exposes window.LB. */
(() => {
  "use strict";

  // Validated palette (dataviz skill, dark surface #0f1a2a). Series: amber, beam, aqua (max 3 in one chart).
  // sodium = highlight/glow, tail = flagged events only (always with a label).
  const C = {
    amber: "#c97c12", beam: "#3987e5", aqua: "#199e70", sodium: "#f2a33a", tail: "#ff5a4e",
    ink: "#e9eef6", fog: "#93a1b6", line: "rgba(156,180,214,0.14)", night: "#0f1a2a", night2: "#15233a", night3: "#1c2d47",
  };
  const SERIES = [C.amber, C.beam, C.aqua];
  const SEQ = ["#2a2c2e", "#5b3a10", "#8a5a14", "#c97c12", "#f2a33a", "#ffd58a"];
  // Diverging (correlations etc.): blue <- neutral grey -> amber, brightest at the extremes so strong
  // values stand out on the dark surface.
  const DIV = ["#6aaaf0", "#3987e5", "#24508a", "#2b3445", "#8a5a14", "#c97c12", "#f2a33a"];
  const SPEED_STOPS = [[0, [122, 62, 10]], [15, [196, 104, 14]], [30, [242, 163, 58]], [50, [255, 213, 138]], [75, [255, 247, 228]]];
  // Standard OSM tiles, recoloured to night by CSS (.tiles-night); CARTO now needs a key.
  const TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
  const ATTR = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';
  const WD = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  // Inside the iPhone app the pages are served at i20://app/ and the data lives in iCloud Drive.
  const inApp = location.protocol === "i20:";
  if (inApp) document.documentElement.classList.add("in-app");

  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => [...root.querySelectorAll(s)];
  const nf = new Intl.NumberFormat("en-IN", { maximumFractionDigits: 0 });
  const nf1 = new Intl.NumberFormat("en-IN", { maximumFractionDigits: 1 });
  const nf2 = new Intl.NumberFormat("en-IN", { maximumFractionDigits: 2 });
  const rupees = (v) => "₹" + nf.format(v);
  const pct = (v, d = 0) => `${(v * 100).toFixed(d)}%`;
  const day = (s) => new Date(s.length === 10 ? s + "T00:00:00" : s);
  const fmtDate = (d, o) => (typeof d === "string" ? day(d) : d).toLocaleDateString("en-GB", o);
  const fmtTime = (d) => (typeof d === "string" ? day(d) : d).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" }).toLowerCase();
  const clock = (h) => fmtTime(new Date(2000, 0, 1, Math.floor(h), Math.round((h % 1) * 60)));
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

  const charts = [];
  const TT = {
    backgroundColor: C.night2, borderColor: C.line, padding: [8, 12],
    textStyle: { color: C.ink, fontSize: 13, fontFamily: "Instrument Sans" },
    extraCssText: "border-radius:8px;box-shadow:none;",
  };
  const FONT = { color: C.fog, fontFamily: "Instrument Sans", fontSize: 12 };
  const axis = (o = {}) => ({
    axisLine: { lineStyle: { color: C.line } }, axisTick: { show: false },
    axisLabel: { ...FONT }, splitLine: { lineStyle: { color: C.line } },
    nameTextStyle: { ...FONT }, ...o,
  });
  function chart(el, option) {
    const node = typeof el === "string" ? $(el) : el;
    const c = echarts.getInstanceByDom(node) || echarts.init(node);
    c.setOption({ textStyle: { fontFamily: "Instrument Sans", color: C.fog }, tooltip: TT, animation: !reduceMotion, ...option });
    if (!charts.includes(c)) charts.push(c);
    return c;
  }
  let raf;
  addEventListener("resize", () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(() => charts.forEach((c) => c.resize())); });

  function baseMap(el, opts = {}) {
    const m = L.map(el, { zoomControl: true, scrollWheelZoom: false, preferCanvas: true, ...opts });
    L.tileLayer(TILES, { attribution: ATTR, maxZoom: 19, className: "tiles-night" }).addTo(m);
    return m;
  }
  function speedColor(s) {
    for (let i = 1; i < SPEED_STOPS.length; i++) {
      const [s1, c1] = SPEED_STOPS[i];
      const [s0, c0] = SPEED_STOPS[i - 1];
      if (s <= s1 || i === SPEED_STOPS.length - 1) {
        const t = Math.max(0, Math.min(1, (s - s0) / (s1 - s0)));
        return `rgb(${c0.map((v, k) => Math.round(v + (c1[k] - v) * t)).join(",")})`;
      }
    }
  }
  // Fit to everyday driving near home, so out-of-town trips don't zoom the city away.
  function coreBounds(latlngs, places = [], q = 0.02) {
    const home = places.find((p) => p.name === "Home");
    if (home) {
      const near = latlngs.filter((p) => Math.abs(p[0] - home.lat) < 0.12 && Math.abs(p[1] - home.lon) < 0.12);
      if (near.length > 50) latlngs = near;
    }
    const lats = latlngs.map((p) => p[0]).sort((a, b) => a - b);
    const lons = latlngs.map((p) => p[1]).sort((a, b) => a - b);
    const at = (arr, f) => arr[Math.min(arr.length - 1, Math.floor(arr.length * f))];
    return L.latLngBounds([at(lats, q), at(lons, q)], [at(lats, 1 - q), at(lons, 1 - q)]);
  }

  async function load(file) {
    try { await document.fonts.ready; } catch {}
    const r = await fetch(file, { cache: "no-store" });
    if (!r.ok) throw new Error(`${file}: ${r.status}`);
    return r.json();
  }
  function fail(msg) {
    if (inApp) msg = "The dashboard appears after the first sync. It starts by itself; tap <b>Sync now</b> to retry.";
    $("main").innerHTML = `<section class="sec"><h2>No data yet</h2><p class="lede">${msg}</p></section>`;
    if (inApp) initSync(); // the app's first run: sync, then reload when it finishes
  }
  // The footer names where the data is stored.
  function storedWhere() {
    const foot = $("#foot");
    if (!foot) return;
    if (inApp) foot.textContent = foot.textContent.replace(/,? stored only on this Mac/, ". Stored in your iCloud Drive (i20_book)");
    else foot.textContent = foot.textContent.replace(/Built from your Bluelink [^.]*?, stored only on this Mac\./, "Built from your iCloud Drive folder (i20_book).");
  }
  // Run page sections independently so one broken chart can't blank the page.
  function run(fns) {
    for (const f of fns) {
      try { f(); } catch (e) { console.error(f.name, e); }
    }
  }

  // ---------- header sync control ----------
  function ago(iso) {
    const m = Math.round((Date.now() - day(iso)) / 60000);
    if (m < 2) return "just now";
    if (m < 60) return `${m} min ago`;
    if (m < 48 * 60) return `${Math.round(m / 60)} h ago`;
    return `${Math.round(m / 1440)} days ago`;
  }
  async function initSync(generatedAt) {
    const label = $("#sync-label"), btn = $("#sync-btn");
    if (!label || !btn) return;
    storedWhere();
    // serve.py step (Mac; the old collect/build/insights labels are kept for reference) and SyncCoordinator steps (iPhone app).
    const STEP = { starting: "Starting…", "analytics/cli.mjs": "Reading iCloud…", "collect.py": "Fetching from Hyundai…", "build_db.py": "Updating archive…", "insights.py": "Recalculating…",
      login: "Logging in to Bluelink…", collect: "Fetching from Hyundai…", analyse: "Recalculating…" };
    let state;
    try { state = await (await fetch("/api/sync")).json(); }
    catch { btn.hidden = true; label.textContent = generatedAt ? `Data from ${ago(generatedAt)}` : ""; return; }
    const show = (s) => {
      label.classList.toggle("err", !!s.error);
      btn.disabled = s.running;
      // `issues`: problems that didn't stop the sync (the app's Settings lists them).
      const issues = s.issues ? ` · ${s.issues} issue${s.issues === 1 ? "" : "s"}` : "";
      const when = s.last_sync || generatedAt;
      label.textContent = s.running ? STEP[s.step] || "Syncing…" : s.error ? s.error : (when ? `Synced ${ago(when)}` : "Not synced yet") + issues;
    };
    const poll = async () => {
      const s = await (await fetch("/api/sync")).json();
      show(s);
      if (s.running) return setTimeout(poll, 1500);
      if (!s.error) location.reload();
    };
    const start = async () => { show(await (await fetch("/api/sync", { method: "POST" })).json()); setTimeout(poll, 1500); };
    btn.addEventListener("click", start);
    show(state);
    if (state.running) setTimeout(poll, 1500);
    else if (!state.error && (!state.last_sync || Date.now() - day(state.last_sync) > 12 * 3600e3)) start();
  }

  window.LB = {
    C, SERIES, SEQ, DIV, WD, TT, FONT, reduceMotion,
    $, $$, nf, nf1, nf2, rupees, pct, day, fmtDate, fmtTime, clock, esc, ago,
    axis, chart, charts, baseMap, speedColor, coreBounds, load, fail, run, initSync,
  };
})();
