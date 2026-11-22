/* Map explorer: every archived route, zoomable, filterable by date, coloured three ways, with a time-lapse. */
(() => {
  "use strict";
  const { C, $, $$, nf, nf1, day, fmtDate, fmtTime, esc, baseMap, speedColor } = LB;

  // Validated trio (amber, beam, aqua) assigned to parts of the day.
  const TOD = [
    { name: "Morning", from: 5, to: 12, color: C.beam },
    { name: "Afternoon", from: 12, to: 17, color: C.aqua },
    { name: "Evening and night", from: 17, to: 29, color: C.amber },
  ];
  const todOf = (h) => TOD.find((p) => (h < 5 ? h + 24 : h) >= p.from && (h < 5 ? h + 24 : h) < p.to);

  let D, map, layer, rend, extras = {}, routed = [], days = [], mode = "trails", playing = null;

  function tripPopup(t) {
    const st = day(t.start);
    const mins = Math.round((day(t.end) - st) / 60000);
    const route = t.from && t.to ? `${esc(t.from)} to ${esc(t.to)}` : t.from ? `From ${esc(t.from)}` : t.to ? `To ${esc(t.to)}` : "";
    return `<b>${fmtDate(st, { weekday: "short", day: "numeric", month: "short", year: "numeric" })}, ${fmtTime(st)}</b><br>
      ${route ? `<span class="muted">${route}</span><br>` : ""}
      ${nf1.format(t.km)} km in ${mins} min, ${Math.round(t.avg)} km/h average, ${Math.round(t.max)} km/h top<br>
      <a href="index.html#trip=${t.id}">Replay this trip</a>`;
  }

  function drawTrip(t) {
    const r = D.routes[t.id];
    const bind = (pl) => pl.bindPopup(() => tripPopup(t), { maxWidth: 280 }).addTo(layer);
    if (mode === "trails") {
      bind(L.polyline(r.map((p) => [p[0], p[1]]), { renderer: rend, color: C.sodium, weight: 1.8, opacity: 0.34, smoothFactor: 1.2 }));
    } else if (mode === "time") {
      bind(L.polyline(r.map((p) => [p[0], p[1]]), { renderer: rend, color: todOf(day(t.start).getHours()).color, weight: 2.4, opacity: 0.6, smoothFactor: 1.2 }));
    } else {
      // Split into runs of similar speed so ~200 trips stay a few thousand polylines, not 37k.
      let run = [[r[0][0], r[0][1]]];
      let bucket = Math.min(16, Math.floor(r[0][2] / 5));
      for (let i = 1; i < r.length; i++) {
        const b = Math.min(16, Math.floor(r[i][2] / 5));
        run.push([r[i][0], r[i][1]]);
        if (b !== bucket || i === r.length - 1) {
          bind(L.polyline(run, { renderer: rend, color: speedColor(bucket * 5 + 2.5), weight: 3, opacity: 0.9 }));
          run = [[r[i][0], r[i][1]]];
          bucket = b;
        }
      }
    }
  }

  function inRange() {
    const a = days[+$("#r-from").value], b = days[+$("#r-to").value];
    return routed.filter((t) => t.day >= a && t.day <= b);
  }

  function legend() {
    const el = $("#legend");
    if (mode === "trails") {
      el.innerHTML = "Brighter where routes overlap: the roads you drive most glow hardest.";
    } else if (mode === "speed") {
      el.innerHTML = `<div class="ramp" style="background:linear-gradient(90deg,${[0, 15, 30, 50, 75].map(speedColor).join(",")})"></div>
        <div class="ends"><span>0 km/h</span><span>75+ km/h</span></div>`;
    } else {
      el.innerHTML = `<div class="keys">${TOD.map((p) => `<span><i style="background:${p.color}"></i>${p.name}</span>`).join("")}</div>`;
    }
  }

  function summary(list) {
    const km = list.reduce((s, t) => s + t.km, 0);
    const a = days[+$("#r-from").value], b = days[+$("#r-to").value];
    $("#m-sub").textContent = `${list.length} trips and ${nf.format(km)} km, ${fmtDate(a, { day: "numeric", month: "short" })} to ${fmtDate(b, { day: "numeric", month: "short", year: "numeric" })}.`;
  }

  // Additive blending (overlaps brighten) only for light trails.
  function blend() {
    if (!rend._ctx) return;
    rend._ctx.globalCompositeOperation = mode === "trails" ? "lighter" : "source-over";
    rend._container.classList.toggle("glow", mode === "trails");
  }

  function redraw() {
    stop();
    layer.clearLayers();
    blend();
    const list = inRange();
    list.forEach(drawTrip);
    summary(list);
    legend();
  }

  function rangeUI() {
    const f = $("#r-from"), t = $("#r-to");
    if (+f.value > +t.value) {
      if (document.activeElement === f) t.value = f.value;
      else f.value = t.value;
    }
    const max = days.length - 1 || 1;
    const fill = $("#range .fill");
    fill.style.left = `${(f.value / max) * 100}%`;
    fill.style.width = `${((t.value - f.value) / max) * 100}%`;
    $("#l-from").textContent = fmtDate(days[f.value], { day: "numeric", month: "short", year: "numeric" });
    $("#l-to").textContent = fmtDate(days[t.value], { day: "numeric", month: "short", year: "numeric" });
  }

  function fit() {
    const pts = inRange().flatMap((t) => D.routes[t.id]);
    if (pts.length) map.fitBounds(LB.coreBounds(pts, D.places, 0.01), { padding: [30, 30], paddingTopLeft: innerWidth > 760 ? [360, 30] : [30, 30] });
  }

  // ---------- extras ----------
  function pin(cls, text) {
    return L.divIcon({ className: "", html: `<div class="pin ${cls}">${text}</div>`, iconSize: [22, 22] });
  }
  function buildExtras() {
    extras.places = L.layerGroup(D.places.map((p) => {
      const cls = p.name === "Home" ? "home" : p.name === "Work" ? "work" : "";
      const label = p.name === "Home" ? "H" : p.name === "Work" ? "W" : p.name.replace("Place ", "");
      return L.marker([p.lat, p.lon], { icon: pin(cls, label) }).bindTooltip(`${p.name}, ${p.visits} visits`);
    }));
    extras.hot = L.layerGroup(D.hotspots.map((h, i) =>
      L.circleMarker([h.lat, h.lon], { radius: 9 + Math.sqrt(h.minutes) / 2, color: C.tail, weight: 2, fillColor: C.tail, fillOpacity: 0.18 })
        .bindTooltip(`Hotspot ${i + 1}: ${h.minutes} min lost over ${h.trips} trips`)));
    extras.park = L.layerGroup(D.status?.park ? [
      L.circleMarker(D.status.park, { radius: 7, color: C.night, weight: 3, fillColor: C.ink, fillOpacity: 1 })
        .bindTooltip(`Parked here as of ${fmtDate(day(D.status.as_of), { day: "numeric", month: "short" })}, ${fmtTime(day(D.status.as_of))}`),
    ] : []);
    for (const [key, id] of [["places", "#t-places"], ["hot", "#t-hot"], ["park", "#t-park"]]) {
      const box = $(id);
      const sync = () => (box.checked ? extras[key].addTo(map) : extras[key].remove());
      box.addEventListener("change", sync);
      sync();
    }
  }

  // ---------- time-lapse ----------
  function stop() {
    if (!playing) return;
    cancelAnimationFrame(playing.raf);
    playing = null;
    $("#replay").textContent = "Play time-lapse";
    $("#lapse").hidden = true;
  }
  function play() {
    if (playing) { stop(); redraw(); return; }
    const list = inRange();
    if (!list.length) return;
    layer.clearLayers();
    $("#replay").textContent = "Stop";
    const lapse = $("#lapse");
    lapse.hidden = false;
    const duration = LB.reduceMotion ? 0 : Math.min(14000, 4000 + list.length * 45);
    const t0 = performance.now();
    let i = 0, km = 0;
    playing = { raf: 0 };
    const step = (now) => {
      const target = duration ? Math.min(list.length, Math.ceil(((now - t0) / duration) * list.length)) : list.length;
      for (; i < target; i++) { drawTrip(list[i]); km += list[i].km; }
      blend();
      const t = list[Math.max(0, i - 1)];
      lapse.innerHTML = `${fmtDate(t.day, { day: "numeric", month: "short" })}<small>${i} trips, ${nf.format(km)} km</small>`;
      if (i < list.length) playing.raf = requestAnimationFrame(step);
      else { playing = null; $("#replay").textContent = "Play time-lapse"; setTimeout(() => { if (!playing) lapse.hidden = true; }, 2500); }
    };
    playing.raf = requestAnimationFrame(step);
  }

  async function main() {
    try { D = await LB.load("data.json"); }
    catch { LB.fail("Run <code>uv run serve.py</code> from the project folder to build it."); return; }
    routed = D.trips.filter((t) => t.route && D.routes[t.id]).map((t) => ({ ...t, day: t.start.slice(0, 10) }));
    days = [...new Set(routed.map((t) => t.day))].sort();
    $("#m-title").textContent = "Where you've driven";

    // One canvas for routes and markers alike: a second canvas on top would swallow route clicks.
    rend = L.canvas({ padding: 0.4, tolerance: 6 });
    rend.on("update", blend);
    map = baseMap("map", { scrollWheelZoom: true, zoomControl: false, preferCanvas: true, renderer: rend });
    window.LBmap = map; // handy in the console
    L.control.zoom({ position: "topright" }).addTo(map);
    L.control.scale({ position: "bottomright", imperial: false }).addTo(map);
    layer = L.layerGroup().addTo(map);

    const f = $("#r-from"), t = $("#r-to");
    f.max = t.max = days.length - 1;
    t.value = days.length - 1;
    $("#range").insertAdjacentHTML("afterbegin", '<div class="fill"></div>');
    let pending;
    for (const el of [f, t]) {
      el.addEventListener("input", () => { rangeUI(); clearTimeout(pending); pending = setTimeout(redraw, 120); });
    }
    $$(".panel .seg button").forEach((b) => b.addEventListener("click", () => {
      mode = b.dataset.mode;
      $$(".panel .seg button").forEach((x) => x.setAttribute("aria-checked", String(x === b)));
      redraw();
    }));
    $("#replay").addEventListener("click", play);
    $("#fit").addEventListener("click", fit);
    $("#panel-toggle").addEventListener("click", (e) => {
      const open = e.currentTarget.getAttribute("aria-expanded") !== "true";
      e.currentTarget.setAttribute("aria-expanded", String(open));
      $("#panel-body").hidden = !open;
    });

    if (matchMedia("(max-width: 760px)").matches) $("#panel-toggle").click();  // start collapsed on phones
    rangeUI();
    redraw();
    fit();
    buildExtras();
    LB.initSync(D.generated_at);
  }
  main();
})();
