/* i20 Logbook. Reads data.json (built by insights.py, or by the iPhone app's analytics) and talks to serve.py
   (or the app) for syncs. running_cost and reminders exist only in the app's output; both stay hidden without them. */
(() => {
  "use strict";

  const { C, SEQ, WD, TT, reduceMotion, $, nf, nf1, nf2, day, fmtDate, fmtTime, clock, esc, axis, chart, baseMap, speedColor } = LB;
  const coreBounds = (latlngs) => LB.coreBounds(latlngs, D.places);
  let D;

  // ---------- hero ----------
  function hero() {
    const map = baseMap("hero-map", { zoomControl: false, dragging: !L.Browser.mobile, doubleClickZoom: false, attributionControl: true });
    const routes = Object.entries(D.routes).sort(([a], [b]) => a.localeCompare(b));
    const all = routes.flatMap(([, r]) => r);
    if (all.length) map.fitBounds(coreBounds(all), { paddingTopLeft: [0, 0], paddingBottomRight: [0, 120] });
    else map.setView([28.46, 77.06], 12);

    // Additive blending turns overlapping routes into brighter streaks, like a long exposure.
    const renderer = L.canvas({ padding: 0.3 });
    const additive = () => renderer._ctx && (renderer._ctx.globalCompositeOperation = "lighter");
    renderer.on("update", additive);
    const draw = (r) => L.polyline(r.map((p) => [p[0], p[1]]), {
      renderer, color: C.sodium, weight: 1.6, opacity: 0.32, interactive: false, smoothFactor: 1.5,
    }).addTo(map);
    if (reduceMotion) {
      routes.forEach(([, r]) => draw(r));
      additive();
    } else {
      let i = 0;
      const per = Math.max(1, Math.ceil(routes.length / 90));
      const step = () => {
        for (let k = 0; k < per && i < routes.length; k++, i++) draw(routes[i][1]);
        additive();
        if (i < routes.length) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    }
    // Light up home and work softly.
    D.places.filter((p) => p.name === "Home" || p.name === "Work").forEach((p) =>
      L.circleMarker([p.lat, p.lon], { radius: 4, color: p.name === "Home" ? C.sodium : C.beam, weight: 2, fillOpacity: 1, fillColor: C.night })
        .bindTooltip(p.name, { direction: "top" }).addTo(map));

    // Odometer
    const odo = $("#odo");
    const text = nf.format(D.status ? D.status.odometer : D.totals.km);
    odo.setAttribute("aria-label", `${text} kilometres`);
    const strips = [];
    for (const ch of text) {
      if (/\d/.test(ch)) {
        const reel = document.createElement("span");
        reel.className = "reel";
        reel.setAttribute("aria-hidden", "true");
        const strip = document.createElement("span");
        strip.className = "strip";
        for (let n = 0; n <= 19; n++) strip.insertAdjacentHTML("beforeend", `<span>${n % 10}</span>`);
        reel.append(strip);
        odo.append(reel);
        strips.push([strip, 10 + Number(ch)]);
      } else {
        odo.insertAdjacentHTML("beforeend", `<span class="sep" aria-hidden="true">${ch}</span>`);
      }
    }
    odo.insertAdjacentHTML("beforeend", '<span class="unit" aria-hidden="true">km</span>');
    requestAnimationFrame(() => requestAnimationFrame(() =>
      strips.forEach(([s, n], i) => {
        s.style.transitionDelay = reduceMotion ? "0s" : `${(strips.length - i) * 0.08}s`;
        s.style.transform = `translateY(${-n * 0.9}em)`;
      })));

    const t = D.totals;
    $("#hero-line").textContent = `${t.trips} trips and ${nf.format(t.hours)} hours behind the wheel since ${fmtDate(day(D.vehicle.reg_date || t.first_day), { day: "numeric", month: "long", year: "numeric" })}.`;
    $("#hero-sub").textContent = `Every bright line is a route you drove. ${Math.round(t.coverage * 100)}% of your kilometres are on record here, and ${t.routed_trips} trips still have their full GPS trace.`;

    // Instrument cluster
    const s = D.status;
    if (!s) { $("#cluster").remove(); return; }
    const pct = Math.max(0, Math.min(100, s.fuel_pct)) / 100;
    const a = Math.PI * (1 - pct);
    const x = 66 + 56 * Math.cos(a), y = 80 - 56 * Math.sin(a);
    const fuelColor = s.low_fuel ? C.tail : C.sodium;
    $("#cluster").innerHTML = `
      <div class="gauge" role="img" aria-label="Fuel ${Math.round(s.fuel_pct)} percent">
        <svg viewBox="0 0 132 92">
          <path d="M10 80 A56 56 0 0 1 122 80" fill="none" stroke="${C.line}" stroke-width="8" stroke-linecap="round"/>
          <path d="M10 80 A56 56 0 0 1 ${x.toFixed(1)} ${y.toFixed(1)}" fill="none" stroke="${fuelColor}" stroke-width="8" stroke-linecap="round"/>
        </svg>
        <div class="val">${Math.round(s.fuel_pct)}%<small>about ${s.fuel_l} L</small></div>
      </div>
      <div class="cl-item"><b>${nf.format(s.range_km)} km</b>range left</div>
      <div class="cl-item"><b class="${s.locked ? "" : "warn"}">${s.locked ? "Locked" : "Unlocked"}</b>doors</div>
      <div class="cl-item">as of ${s.as_of ? `${fmtDate(day(s.as_of), { day: "numeric", month: "short" })}, ${fmtTime(day(s.as_of))}` : "unknown"}</div>`;
  }

  // ---------- year ----------
  function year() {
    $("#f-year").textContent = D.findings.year;
    const days = D.days;
    const kms = days.map((d) => d[1]).sort((a, b) => a - b);
    const p95 = kms[Math.floor(kms.length * 0.95)] || 1;
    const byDay = Object.fromEntries(days.map((d) => [d[0], d]));
    const cal = chart("#c-calendar", {
      tooltip: { ...TT, formatter: (p) => {
        const d = byDay[p.value[0]];
        return `<b>${fmtDate(day(p.value[0]), { weekday: "long", day: "numeric", month: "long" })}</b><br>${nf1.format(d[1])} km in ${d[2]} trip${d[2] > 1 ? "s" : ""}`;
      } },
      visualMap: {
        min: 0, max: p95, calculable: false, orient: "horizontal", right: 0, bottom: 0,
        itemWidth: 10, itemHeight: 140, text: [`${nf.format(p95)}+ km`, "0"], textStyle: { color: C.fog, fontFamily: "Instrument Sans" },
        inRange: { color: SEQ.slice(1) },
      },
      calendar: {
        range: [D.totals.first_day, D.totals.last_day], top: 24, left: 40, right: 8, bottom: 40,
        cellSize: ["auto", 20], splitLine: { show: false },
        itemStyle: { color: C.night2, borderColor: C.night, borderWidth: 3 },
        dayLabel: { firstDay: 1, color: C.fog, fontFamily: "Instrument Sans", nameMap: ["Sun", "Mon", "", "Wed", "", "Fri", ""] },
        monthLabel: { color: C.fog, fontFamily: "Instrument Sans", nameMap: "en" }, yearLabel: { show: false },
      },
      series: [{ type: "heatmap", coordinateSystem: "calendar", data: days.map((d) => [d[0], d[1]]) }],
    });
    cal.on("click", (p) => showDay(p.value[0]));

    const best = Math.max(...D.months.map((m) => m[1]));
    chart("#c-months", {
      grid: { left: 48, right: 8, top: 12, bottom: 28 },
      tooltip: { ...TT, trigger: "axis", axisPointer: { type: "shadow", shadowStyle: { color: "rgba(156,180,214,0.06)" } },
        formatter: ([p]) => { const m = D.months[p.dataIndex];
          return `<b>${fmtDate(day(m[0] + "-01"), { month: "long", year: "numeric" })}</b><br>${nf.format(m[1])} km, ${m[2]} trips<br>${m[3]} km/h average moving speed`; } },
      xAxis: axis({ type: "category", data: D.months.map((m) => fmtDate(day(m[0] + "-01"), { month: "short" })) }),
      yAxis: axis({ type: "value", splitNumber: 3, axisLabel: { color: C.fog, formatter: (v) => nf.format(v) } }),
      series: [{ type: "bar", barMaxWidth: 30, data: D.months.map((m) => ({
        value: m[1], itemStyle: { color: m[1] === best ? C.sodium : C.amber, borderRadius: [4, 4, 0, 0] } })) }],
    });
    showDay(days[days.length - 1][0]);
  }

  function tripLine(t) {
    const st = day(t.start);
    const mins = Math.round((day(t.end) - st) / 60000);
    const route = t.from && t.to ? `${t.from} to ${t.to}` : t.from ? `From ${t.from}` : t.to ? `To ${t.to}` : "";
    return { st, mins, route };
  }

  function showDay(dateStr) {
    const list = D.trips.filter((t) => t.start.startsWith(dateStr));
    const km = list.reduce((a, t) => a + t.km, 0);
    $("#day-panel").innerHTML = `
      <h3>${fmtDate(day(dateStr), { weekday: "long", day: "numeric", month: "long" })}</h3>
      <p class="muted">${list.length ? `${nf1.format(km)} km in ${list.length} trip${list.length > 1 ? "s" : ""}` : "No driving this day."}</p>
      <ul class="day-trips">${list.map((t) => { const { st, mins, route } = tripLine(t);
        return `<li><span class="t">${fmtTime(st)}</span><span>${nf1.format(t.km)} km, ${mins} min${route ? `<br><span class="muted">${esc(route)}</span>` : ""}</span>
          ${t.route ? `<button type="button" data-trip="${t.id}">Replay</button>` : '<span class="muted">no route</span>'}</li>`; }).join("")}</ul>`;
    $("#day-panel").querySelectorAll("[data-trip]").forEach((b) => b.addEventListener("click", () => {
      selectTrip(b.dataset.trip, true);
      $("#trips").scrollIntoView();
    }));
  }

  // ---------- rhythm ----------
  function rhythm() {
    $("#f-rhythm").textContent = D.findings.rhythm;
    const data = [];
    let max = 1;
    D.rhythm.forEach((row, wd) => row.forEach((n, h) => { data.push([h, wd, n || null]); max = Math.max(max, n); }));
    const hourLabel = (h) => (h % 12 || 12) + (h < 12 ? "a" : "p");
    chart("#c-rhythm", {
      grid: { left: 44, right: 8, top: 8, bottom: 56 },
      tooltip: { ...TT, formatter: (p) => `<b>${WD[p.value[1]]}, ${clock(p.value[0])}</b><br>${p.value[2] || 0} trips started` },
      xAxis: axis({ type: "category", data: [...Array(24).keys()].map(hourLabel), splitLine: { show: false },
        axisLabel: { color: C.fog, interval: 2 } }),
      yAxis: axis({ type: "category", data: WD.map((w) => w.slice(0, 3)), inverse: true, splitLine: { show: false } }),
      visualMap: { min: 1, max, orient: "horizontal", left: 44, bottom: 0, itemWidth: 10, itemHeight: 140,
        text: [`${max} trips`, "1"], textStyle: { color: C.fog, fontFamily: "Instrument Sans" }, inRange: { color: SEQ.slice(1) } },
      series: [{ type: "heatmap", data, itemStyle: { borderColor: C.night, borderWidth: 2, borderRadius: 3 } }],
    });
    const top = D.weekday_km.indexOf(Math.max(...D.weekday_km));
    chart("#c-weekday", {
      grid: { left: 44, right: 40, top: 8, bottom: 24 },
      tooltip: { ...TT, formatter: (p) => `<b>${WD[p.dataIndex]}</b><br>${nf1.format(p.value)} km on an average week` },
      xAxis: axis({ type: "value", splitNumber: 3 }),
      yAxis: axis({ type: "category", inverse: true, data: WD.map((w) => w.slice(0, 3)), splitLine: { show: false } }),
      series: [{ type: "bar", barMaxWidth: 22, label: { show: true, position: "right", color: C.fog, formatter: (p) => nf.format(p.value) },
        data: D.weekday_km.map((v, i) => ({ value: v, itemStyle: { color: i === top ? C.sodium : C.amber, borderRadius: [0, 4, 4, 0] } })) }],
    });
  }

  // ---------- commute ----------
  function commute() {
    const w = D.commute.to_work, h = D.commute.to_home;
    $("#f-commute").textContent = D.findings.commute_to_work || "Your commute, trip by trip.";
    $("#f-commute-2").textContent = (D.findings.commute_to_home || "") + " Each dot is one drive: when you left, and how long it took.";
    const pts = (arr) => arr.map((t) => { const d = day(t.start); return [d.getHours() + d.getMinutes() / 60, t.min, t.start, t.km]; });
    chart("#c-commute", {
      grid: { left: 56, right: 12, top: 40, bottom: 32 },
      legend: { top: 0, left: 0, textStyle: { color: C.ink }, itemWidth: 10, itemHeight: 10, icon: "circle" },
      tooltip: { ...TT, formatter: (p) => `<b>${p.seriesName}</b><br>${fmtDate(day(p.value[2]), { weekday: "short", day: "numeric", month: "short" })}, left ${clock(p.value[0])}<br>${p.value[1]} min for ${p.value[3]} km` },
      xAxis: axis({ type: "value", min: (v) => Math.floor(v.min) - 0.5, max: (v) => Math.ceil(v.max) + 0.5, splitLine: { show: false },
        axisLabel: { color: C.fog, formatter: (v) => (Number.isInteger(v) ? clock(v) : "") } }),
      yAxis: axis({ type: "value", splitNumber: 4, axisLabel: { color: C.fog, fontFamily: "Instrument Sans", formatter: "{value} min" } }),
      series: [["To work", w, C.amber], ["Home", h, C.beam]].map(([name, arr, color]) => ({
        name, type: "scatter", data: pts(arr), symbolSize: 10,
        itemStyle: { color, borderColor: C.night, borderWidth: 2 }, emphasis: { scale: 1.4 },
      })),
    });
    const fig = (label, arr, color) => {
      if (!arr.length) return "";
      const m = arr.map((t) => t.min).sort((a, b) => a - b);
      const med = m[Math.floor(m.length / 2)];
      return `<div class="fig"><div class="k"><i style="background:${color}"></i>${label}</div>
        <div class="n">${med}<small>min typical</small></div>
        <p>${m.length} drives. Quickest ${m[0]} min, slowest ${m[m.length - 1]} min.</p></div>`;
    };
    $("#commute-figs").innerHTML = fig("Home to work", w, C.amber) + fig("Work to home", h, C.beam)
      || '<p class="muted">Home and work show up once there are enough trips with routes.</p>';
  }

  // ---------- traffic ----------
  function traffic() {
    $("#f-traffic").textContent = D.findings.traffic;
    $("#f-hotspots").textContent = D.findings.hotspots + " The glow shows everywhere you've crawled below 8 km/h.";
    const map = baseMap("traffic-map");
    const slow = [];
    const net = [];
    for (const r of Object.values(D.routes)) {
      net.push(r.map((p) => [p[0], p[1]]));
      for (let i = 6; i < r.length - 6; i++) if (r[i][2] < 8) slow.push([r[i][0], r[i][1], 1]);
    }
    const renderer = L.canvas();
    net.forEach((l) => L.polyline(l, { renderer, color: C.fog, weight: 1, opacity: 0.12, interactive: false }).addTo(map));
    L.heatLayer(slow, { radius: 14, blur: 14, minOpacity: 0.3, max: 3,
      gradient: { 0.25: "#5b3a10", 0.5: "#c97c12", 0.8: "#f2a33a", 1: "#ffe2a8" } }).addTo(map);
    D.places.filter((p) => p.name === "Home" || p.name === "Work").forEach((p) =>
      L.marker([p.lat, p.lon], { icon: L.divIcon({ className: "", html: `<div class="pin ${p.name.toLowerCase()}">${p.name[0]}</div>`, iconSize: [22, 22] }) })
        .bindTooltip(p.name).addTo(map));
    const markers = D.hotspots.map((h, i) => L.marker([h.lat, h.lon], {
      icon: L.divIcon({ className: "", html: `<div class="pin">${i + 1}</div>`, iconSize: [22, 22] }),
    }).bindTooltip(`${h.minutes} min lost over ${h.trips} trips`).addTo(map));
    const pts = D.hotspots.map((h) => [h.lat, h.lon]).concat(D.places.filter((p) => p.name === "Home" || p.name === "Work").map((p) => [p.lat, p.lon]));
    if (pts.length) map.fitBounds(L.latLngBounds(pts), { padding: [40, 40] });

    const list = $("#hotspot-list");
    list.innerHTML = D.hotspots.map((h, i) => `<li><button type="button" data-i="${i}">
      <span class="r">${i + 1}</span>
      <span><span class="m">${h.minutes} min</span><br><span class="d">${h.trips} trips through here, ${h.per_trip} min lost each time</span></span>
      <span class="d">Show</span></button></li>`).join("") || '<li class="muted">No hotspots yet.</li>';
    list.querySelectorAll("button").forEach((b) => b.addEventListener("click", () => {
      list.querySelectorAll("button").forEach((x) => x.classList.toggle("on", x === b));
      const h = D.hotspots[b.dataset.i];
      map.flyTo([h.lat, h.lon], 16, { duration: reduceMotion ? 0 : 0.8 });
      markers[b.dataset.i].openTooltip();
    }));

    const worst = Math.max(...D.idle_by_hour.map((r) => r[1]));
    chart("#c-idle", {
      grid: { left: 44, right: 8, top: 12, bottom: 28 },
      tooltip: { ...TT, formatter: (p) => { const r = D.idle_by_hour[p.dataIndex];
        return `<b>Trips starting ${clock(r[0])}</b><br>${Math.round(r[1] * 100)}% of the time standing still<br>${r[2]} trips`; } },
      xAxis: axis({ type: "category", data: D.idle_by_hour.map((r) => clock(r[0]).replace(":00", "")) }),
      yAxis: axis({ type: "value", splitNumber: 3, axisLabel: { color: C.fog, formatter: (v) => `${Math.round(v * 100)}%` } }),
      series: [{ type: "bar", barMaxWidth: 22, data: D.idle_by_hour.map((r) => ({
        value: r[1], itemStyle: { color: r[1] === worst ? C.sodium : C.amber, borderRadius: [4, 4, 0, 0] } })) }],
    });
  }

  // ---------- trips ----------
  let tripMap, tripLayer, tripMarker, speedChart, tripFilter = "route", currentTrip = null;

  function trips() {
    const routed = D.trips.filter((t) => t.route).length;
    $("#trips-lede").textContent = `${routed} of your ${D.trips.length} trips still have a GPS trace. Pick one to replay it; hover the speed line to follow along on the map. Older trips keep their numbers but Hyundai deleted their routes after about three months.`;
    tripMap = baseMap("trip-map");
    tripLayer = L.layerGroup().addTo(tripMap);
    $("#trip-map").insertAdjacentHTML("afterend", '<div class="legend-speed">Speed <span>0</span><i></i><span>75+ km/h</span></div>');
    speedChart = chart("#c-speed", { grid: { left: 44, right: 8, top: 12, bottom: 24 } });
    speedChart.on("updateAxisPointer", (e) => {
      const i = e.dataIndex ?? e.axesInfo?.[0]?.value;
      const r = currentTrip && D.routes[currentTrip.id];
      if (r && r[i] && tripMarker) tripMarker.setLatLng([r[i][0], r[i][1]]).setStyle({ opacity: 1, fillOpacity: 1 });
    });
    document.querySelectorAll(".seg button").forEach((b) => b.addEventListener("click", () => {
      tripFilter = b.dataset.filter;
      document.querySelectorAll(".seg button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
      renderTripList();
    }));
    renderTripList();
    const linked = location.hash.match(/^#trip=(\d+)$/)?.[1];
    const latest = [...D.trips].reverse().find((t) => t.route) || D.trips[D.trips.length - 1];
    if (linked && D.trips.some((t) => t.id === linked)) {
      selectTrip(linked, true);
      requestAnimationFrame(() => $("#trips").scrollIntoView());
    } else if (latest) selectTrip(latest.id);
  }

  function renderTripList() {
    const items = [...D.trips].reverse().filter((t) => tripFilter === "all" || t.route);
    const ul = $("#trip-list");
    ul.innerHTML = items.map((t) => {
      const { st, mins, route } = tripLine(t);
      const ev = t.events.reduce((a, b) => a + b, 0);
      return `<li><button type="button" data-trip="${t.id}" aria-current="${currentTrip?.id === t.id}">
        <span class="when">${fmtDate(st, { weekday: "short", day: "numeric", month: "short" })}, ${fmtTime(st)}</span>
        <span class="km">${nf1.format(t.km)} km</span>
        <span class="what">${esc(route ? `${route}, ${mins} min` : `${mins} min`)}${t.route ? "" : ", no route"}</span>
        <span class="flag">${ev ? `${ev} alert${ev > 1 ? "s" : ""}` : ""}</span></button></li>`;
    }).join("");
    ul.querySelectorAll("button").forEach((b) => b.addEventListener("click", () => selectTrip(b.dataset.trip)));
  }

  function selectTrip(id, ensureVisible) {
    const t = D.trips.find((x) => x.id === id);
    if (!t) return;
    if (ensureVisible && !t.route && tripFilter === "route") { tripFilter = "all"; renderTripList(); }
    currentTrip = t;
    $("#trip-list").querySelectorAll("button").forEach((b) => {
      const on = b.dataset.trip === id;
      b.setAttribute("aria-current", String(on));
      if (on && ensureVisible) b.scrollIntoView({ block: "nearest" });
    });
    const { st, mins, route } = tripLine(t);
    const [hb, ra, os] = t.events;
    const alerts = [hb && `${hb} harsh braking`, ra && `${ra} rapid acceleration`, os && `${os} speeding`].filter(Boolean);
    $("#trip-stats").innerHTML = `
      <div class="title"><b>${fmtDate(st, { weekday: "long", day: "numeric", month: "long" })}, ${fmtTime(st)}</b>${esc(route)}</div>
      <div><b>${nf1.format(t.km)} km</b>distance</div>
      <div><b>${mins} min</b>${Math.round(t.idle)} min of it standing still</div>
      <div><b>${Math.round(t.avg)} km/h</b>average while moving</div>
      <div><b>${Math.round(t.max)} km/h</b>top speed</div>
      <div><b style="color:${alerts.length ? C.tail : C.ink}">${alerts.length ? alerts.length : "None"}</b>${alerts.length ? esc(alerts.join(", ")) : "alerts"}</div>`;

    tripLayer.clearLayers();
    const r = D.routes[id];
    $("#trip-map").querySelector(".no-route")?.remove();
    if (!r) {
      $("#trip-map").insertAdjacentHTML("beforeend", '<div class="no-route" style="position:absolute;inset:0;z-index:500;background:rgba(10,18,32,.85)">Hyundai deleted this trip\'s route before archiving started.<br>Its distance, times and speeds are kept above.</div>');
      speedChart.clear();
      tripMap.setView(tripMap.getCenter(), tripMap.getZoom());
      return;
    }
    const renderer = L.canvas();
    L.polyline(r.map((p) => [p[0], p[1]]), { renderer, color: "#05090f", weight: 9, opacity: 0.8, interactive: false }).addTo(tripLayer);
    for (let i = 1; i < r.length; i++) {
      L.polyline([[r[i - 1][0], r[i - 1][1]], [r[i][0], r[i][1]]], { renderer, color: speedColor(r[i][2]), weight: 5, opacity: 0.95, interactive: false }).addTo(tripLayer);
    }
    L.circleMarker([r[0][0], r[0][1]], { radius: 6, color: C.ink, weight: 2, fillColor: C.night, fillOpacity: 1 }).bindTooltip("Start").addTo(tripLayer);
    L.circleMarker([r[r.length - 1][0], r[r.length - 1][1]], { radius: 6, color: C.ink, weight: 2, fillColor: C.ink, fillOpacity: 1 }).bindTooltip("End").addTo(tripLayer);
    tripMarker = L.circleMarker([r[0][0], r[0][1]], { radius: 8, color: C.night, weight: 3, fillColor: C.beam, fillOpacity: 0, opacity: 0 }).addTo(tripLayer);
    tripMap.fitBounds(L.latLngBounds(r.map((p) => [p[0], p[1]])), { padding: [30, 30], animate: !reduceMotion });

    const t0 = st.getTime();
    speedChart.setOption({
      tooltip: { ...TT, trigger: "axis", axisPointer: { type: "line", lineStyle: { color: C.fog } },
        formatter: ([p]) => `${fmtTime(new Date(t0 + r[p.dataIndex][3] * 1000))}<br><b>${Math.round(p.value)} km/h</b>` },
      xAxis: axis({ type: "category", boundaryGap: false, data: r.map((p) => p[3]), splitLine: { show: false },
        axisLabel: { color: C.fog, interval: Math.ceil(r.length / 6), formatter: (v) => fmtTime(new Date(t0 + v * 1000)) } }),
      yAxis: axis({ type: "value", splitNumber: 3, name: "km/h", nameTextStyle: { color: C.fog, align: "left" } }),
      series: [{ type: "line", data: r.map((p) => p[2]), showSymbol: false, smooth: 0.3, lineStyle: { color: C.sodium, width: 2 },
        areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: "rgba(242,163,58,0.35)" }, { offset: 1, color: "rgba(242,163,58,0)" }]) } }],
    }, { replaceMerge: ["series", "xAxis", "yAxis"] });
  }

  // ---------- style ----------
  function style() {
    $("#f-style").textContent = D.findings.style;
    const t = D.totals;
    const per1000 = (n) => (t.km ? (n / t.km) * 1000 : 0);
    const ev = (n, label, what) => `<div class="ev ${n ? "has" : ""}"><div class="n">${n}</div><div class="k">${label}</div>
      <p>${n ? `${nf1.format(per1000(n))} per 1,000 km. ${what}` : "None recorded."}</p></div>`;
    $("#events").innerHTML = ev(t.hard_brake, "Harsh braking", "Sudden stops the car flagged.")
      + ev(t.rapid_accel, "Rapid acceleration", "Hard launches the car flagged.")
      + ev(t.overspeed, "Speeding", "Times the car logged excessive speed.");

    const bins = {};
    D.trips.forEach((x) => { const b = Math.floor(x.max / 10) * 10; bins[b] = (bins[b] || 0) + 1; });
    const keys = Object.keys(bins).map(Number).sort((a, b) => a - b);
    const full = [];
    for (let b = keys[0]; b <= keys[keys.length - 1]; b += 10) full.push([b, bins[b] || 0]);
    chart("#c-topspeed", {
      grid: { left: 44, right: 8, top: 12, bottom: 28 },
      tooltip: { ...TT, formatter: (p) => `<b>${full[p.dataIndex][0]}–${full[p.dataIndex][0] + 9} km/h</b><br>${p.value} trips` },
      xAxis: axis({ type: "category", data: full.map((b) => b[0]) , axisLabel: { color: C.fog, interval: 1 } }),
      yAxis: axis({ type: "value", splitNumber: 3 }),
      series: [{ type: "bar", barCategoryGap: "12%", data: full.map((b) => ({ value: b[1], itemStyle: { color: b[0] >= 100 ? C.sodium : C.amber, borderRadius: [4, 4, 0, 0] } })) }],
    });

    const edges = [[0, 2, "Under 2"], [2, 5, "2–5"], [5, 10, "5–10"], [10, 20, "10–20"], [20, 50, "20–50"], [50, 1e9, "50+"]];
    const counts = edges.map(([a, b]) => D.trips.filter((x) => x.km >= a && x.km < b).length);
    chart("#c-lengths", {
      grid: { left: 44, right: 8, top: 12, bottom: 28 },
      tooltip: { ...TT, formatter: (p) => `<b>${edges[p.dataIndex][2]} km</b><br>${p.value} trips` },
      xAxis: axis({ type: "category", data: edges.map((e) => e[2] + " km") }),
      yAxis: axis({ type: "value", splitNumber: 3 }),
      series: [{ type: "bar", barMaxWidth: 40, data: counts.map((v, i) => ({ value: v, itemStyle: { color: i < 2 ? C.sodium : C.amber, borderRadius: [4, 4, 0, 0] } })) }],
    });
    $("#f-short").textContent = D.findings.short;
  }

  // ---------- car ----------
  const inDays = (d) => d < 60 ? `in ${d} days` : d < 730 ? `in ${Math.round(d / 30.44)} months` : `in ${Math.round(d / 365.25)} years`;
  function car() {
    const svc = D.service;
    if (!svc.length) { $("#f-service").textContent = "Service schedule appears after the first sync."; return; }
    const next = svc[0];
    $("#f-service").textContent = `Your next service is due by ${fmtDate(day(next.due), { day: "numeric", month: "long" })}, ${next.days_left} days from now.`;
    const ms = D.milestones[D.milestones.length - 1];
    const lastVisit = D.services[D.services.length - 1];
    const assumed = svc.filter((s) => !s.last_done).map((s) => s.item.toLowerCase());
    $("#f-service-2").textContent = (lastVisit
      ? `Items replaced at your last service (${fmtDate(day(lastVisit.date), { day: "numeric", month: "long", year: "numeric" })}, ${nf.format(lastVisit.odometer_km)} km) count from that visit. The others (${assumed.join(", ")}) aren't on any logged invoice, so they count from registration as if done on schedule; if one was done, add it to that visit in service_log.json. `
      : ms ? `The car passed ${nf.format(ms.km)} km around ${fmtDate(day(ms.date), { day: "numeric", month: "long" })}. These dates assume that service was done; check your service book. ` : "")
      + `Each item is due at its distance or its time limit, whichever comes first. Distance dates use your recent pace of ${nf1.format(D.totals.pace_90d)} km a day.`;
    const rows = svc.map((s) => {
      const span = s.trigger === "time" ? s.every_months * 30.44 : s.every_km / Math.max(D.totals.pace_90d, 1);
      const done = Math.max(0.02, Math.min(1, 1 - s.days_left / span));
      const soon = s.days_left < 60;
      const limit = s.every_months ? `every ${nf.format(s.every_km)} km or ${s.every_months} months` : `every ${nf.format(s.every_km)} km, no time limit from Hyundai`;
      const last = s.last_done ? `<small class="last">replaced ${fmtDate(day(s.last_done.date), { day: "numeric", month: "short", year: "numeric" })} at ${nf.format(s.last_done.km)} km</small>` : "";
      return `<div class="svc-row"><div class="name">${esc(s.item)}<small>${limit}</small>${last}</div>
        <div class="svc-track" role="img" aria-label="${Math.round(done * 100)}% of the interval used"><div class="fill ${soon ? "soon" : ""}" style="width:${(done * 100).toFixed(1)}%"></div></div>
        <div class="due"><b>${fmtDate(day(s.due), { day: "numeric", month: "short", year: "numeric" })}</b>
        <small>${s.trigger === "time" ? inDays(s.days_left) : `at ${nf.format(s.km_due)} km`}</small></div></div>`;
    }).join("");
    $("#service").innerHTML = `<div class="svc-rows">${rows}</div>`;
    visits();
    tank();
    const t = D.totals;
    $("#coverage").innerHTML = `<div class="n">${Math.round(t.coverage * 100)}%</div>
      <p>of the ${nf.format(D.status?.odometer || t.km)} km on the odometer is in this archive: ${nf.format(t.km)} km over ${t.trips} trips since ${fmtDate(day(t.first_day), { day: "numeric", month: "long", year: "numeric" })}. The rest was driven before the first recorded trip.</p>`;
    $("#foot").textContent = `Built from your Bluelink data, stored only on this Mac. Last rebuilt ${fmtDate(day(D.generated_at), { day: "numeric", month: "short" })}, ${fmtTime(day(D.generated_at))}.`;
  }

  // Running cost per km (app output only). The fuel share is the fuel model's estimate, not receipts.
  function cost() {
    const rc = D.running_cost;
    if (!rc || !rc.per_km || rc.per_km.total == null) return;
    const rows = [["fuel (est.)", rc.per_km.fuel, rc.fuel_rs, C.amber], ["service", rc.per_km.service, rc.service_rs, C.beam],
      ["other", rc.per_km.other, rc.other_rs, C.aqua]];
    $("#running-cost").hidden = false;
    chart("#c-cost", {
      grid: { left: 84, right: 56, top: 8, bottom: 24 },
      tooltip: { ...TT, formatter: (p) => { const r = rows[p.dataIndex];
        return p.dataIndex === 0
          ? `<b>${r[0]}</b><br>₹${nf2.format(r[1] ?? 0)} per km, modelled<br>₹${nf.format(r[2] ?? 0)} over the km in the trip archive`
          : `<b>${r[0]}</b><br>₹${nf2.format(r[1] ?? 0)} per km<br>₹${nf.format(r[2] ?? 0)} over ${nf.format(rc.km)} km on the odometer`; } },
      xAxis: axis({ type: "value", splitNumber: 3, axisLabel: { color: C.fog, formatter: (v) => `₹${v}` } }),
      yAxis: axis({ type: "category", inverse: true, data: rows.map((r) => r[0]), splitLine: { show: false } }),
      series: [{ type: "bar", barMaxWidth: 22, data: rows.map((r) => ({ value: r[1] ?? 0, itemStyle: { color: r[3], borderRadius: [0, 4, 4, 0] } })),
        label: { show: true, position: "right", color: C.ink, formatter: (p) => `₹${nf2.format(p.value)}` } }],
    });
    $("#f-cost").textContent = `About ₹${nf2.format(rc.per_km.total)} per km in all. Fuel is the fuel model's estimate per km over the trips in the archive (each trip's modelled litres at the pump price), not summed from receipts; service and other are what you logged, spread over all ${nf.format(rc.km)} km on the odometer.`;
  }

  // Reminders the owner set on maintenance entries (app output only).
  const REMINDER = { puc: "PUC renewal", insurance: "Insurance renewal", tyres: "Tyres", battery: "Battery", wipers: "Wipers", repair: "Repair", wash: "Wash", other: "Reminder" };
  const relDays = (d) => d === 0 ? "today" : d === 1 ? "tomorrow" : d === -1 ? "yesterday" : d < 0 ? `${-d} days ago` : inDays(d);
  function reminders() {
    const rs = D.reminders;
    if (!rs || !rs.length) return;
    const el = $("#reminders");
    el.hidden = false;
    const line = (r) => `${REMINDER[r.category] || r.category} · ${fmtDate(day(r.date), { day: "numeric", month: "short" })} · ${relDays(r.days_left)}`;
    el.innerHTML = `<h3>Reminders</h3>` + rs.map((r) => `<div class="svc-row${r.days_left >= 0 && r.days_left < 14 ? " soon" : ""}"><div class="name">${esc(line(r))}${r.note ? `<small>${esc(r.note)}</small>` : ""}</div></div>`).join("");
  }

  function visits() {
    if (!D.services.length) return;
    const spent = D.services.reduce((a, v) => a + v.total, 0);
    const km = D.status?.odometer || D.totals.km;
    const cards = D.services.slice().reverse().map((v) => {
      const lines = [...v.parts, ...v.labour].filter((x) => x.amount > 0)
        .map((x) => `<tr><td>${esc(x.name)}${x.qty !== 1 ? `<small>${nf1.format(x.qty)} ${esc(x.unit || "")} × ₹${nf.format(x.amount / x.qty)}</small>` : ""}</td><td>₹${nf2.format(x.amount)}</td></tr>`).join("");
      return `<article class="visit"><header><b>${fmtDate(day(v.date), { day: "numeric", month: "long", year: "numeric" })} · ${nf.format(v.odometer_km)} km</b>
        <span>${esc(v.kind)}, ${esc(v.workshop)}</span></header>
        <table>${lines}<tr class="sub"><td>GST on parts</td><td>₹${nf2.format(v.gst)}</td></tr>
        <tr class="total"><td>Paid</td><td>₹${nf.format(v.total)}</td></tr></table>
        ${v.notes ? `<p>${esc(v.notes)}</p>` : ""}</article>`;
    }).join("");
    const perKm = spent / km;
    $("#visits").innerHTML = cards + `<p class="note">Workshop bills so far: ₹${nf.format(spent)}, or ₹${perKm.toFixed(2)} per km over ${nf.format(km)} km`
      + (D.fuel_rs_per_km ? `, next to ₹${D.fuel_rs_per_km.toFixed(2)} per km for fuel.` : ".") + `</p>`;
  }

  function tank() {
    const T = D.tank, cap = 37;
    if (!T || !T.points.length) {
      $("#c-fuel").innerHTML = `<p class="note">Add your fuel log CSV to the project folder to model the tank level.</p>`;
      $("#c-fuel").style.height = "auto";
      return;
    }
    const pts = T.points, z = 1.96;
    const lo = pts.map((p) => [p[0], p[1] == null ? null : Math.max(0, p[1] - z * p[2])]);
    const band = pts.map((p, i) => [p[0], p[1] == null ? null : Math.min(cap, p[1] + z * p[2]) - lo[i][1]]);
    const gauge = T.gauge.map((g) => [g[0], +(g[1] / 100 * cap).toFixed(1), g[1], g[2], g[3]]);
    const lvlAt = (t) => { let v = null; for (const p of pts) { if (p[0] > t) break; v = p; } return v; };
    const fills = T.fills.map((f) => { const p = lvlAt(f[0]); return [f[0], p?.[1] ?? null, f[1], f[2]]; }).filter((f) => f[1] != null);
    const last = Date.parse(pts[pts.length - 1][0]), from = last - 60 * 864e5, first = Date.parse(pts[0][0]);
    const startPct = Math.max(0, (from - first) / (last - first) * 100);
    const dt = (s) => `${fmtDate(day(s), { day: "numeric", month: "short", year: "numeric" })}, ${fmtTime(day(s))}`;
    chart("#c-fuel", {
      grid: { left: 48, right: 16, top: 16, bottom: 72 },
      tooltip: { ...TT, trigger: "axis", formatter: (ps) => {
        const m = ps.find((p) => p.seriesName === "Model"), g = ps.find((p) => p.seriesName === "Gauge"), f = ps.find((p) => p.seriesName === "Fill");
        const at = (m || g || f).value[0], p = lvlAt(at);
        let h = `<b>${dt(at)}</b>`;
        if (p && p[1] != null) h += `<br>Model: ${nf1.format(p[1])} L (${Math.round(p[1] / cap * 100)}%) ± ${nf1.format(z * p[2])} L`;
        if (g) h += `<br>Gauge: ${g.value[2]}% ≈ ${nf1.format(g.value[1])} L, ${nf.format(g.value[3])} km range`;
        if (f) h += `<br>Fill: ${nf1.format(f.value[2])} L${f.value[3] ? " (to the brim)" : ""}`;
        return h; } },
      xAxis: axis({ type: "time", splitLine: { show: false }, axisLabel: { color: C.fog, hideOverlap: true } }),
      yAxis: axis({ type: "value", min: 0, max: cap, interval: cap / 4, axisLabel: { color: C.fog, formatter: (v) => ["E", "¼", "½", "¾", "F"][Math.round(v / cap * 4)] } }),
      dataZoom: [{ type: "inside", start: startPct, end: 100 },
        { type: "slider", start: startPct, end: 100, height: 22, bottom: 16, borderColor: C.line, fillerColor: "rgba(242,163,58,0.12)",
          dataBackground: { lineStyle: { color: C.fog, opacity: 0.4 }, areaStyle: { opacity: 0 } }, textStyle: { color: C.fog }, labelFormatter: (v) => fmtDate(new Date(v), { day: "numeric", month: "short" }) }],
      series: [
        { name: "lo", type: "line", data: lo, stack: "band", symbol: "none", lineStyle: { opacity: 0 }, tooltip: { show: false } },
        { name: "band", type: "line", data: band, stack: "band", symbol: "none", lineStyle: { opacity: 0 }, areaStyle: { color: C.amber, opacity: 0.18 }, tooltip: { show: false } },
        { name: "Model", type: "line", data: pts.map((p) => [p[0], p[1]]), symbol: "none", lineStyle: { color: C.amber, width: 1.6 },
          markArea: { silent: true, itemStyle: { color: "rgba(147,161,182,0.07)" }, label: { color: C.fog, fontSize: 11, position: "insideTop" },
            data: T.gaps.map(([a, b]) => [{ xAxis: a, name: "Fill missing from log" }, { xAxis: b }]) } },
        { name: "Fill", type: "scatter", data: fills, symbol: "triangle", symbolSize: 9, itemStyle: { color: C.sodium } },
        { name: "Gauge", type: "scatter", data: gauge, symbolSize: 9, itemStyle: { color: C.beam, borderColor: C.night, borderWidth: 1.5 }, z: 5 },
      ],
    });
    const g = gauge.filter((x) => x[4] != null), lg = g[g.length - 1];
    const gap = g.map((x) => x[1] - x[4] / 100 * cap), mean = gap.reduce((a, b) => a + b, 0) / (gap.length || 1);
    const lp = lvlAt(lg?.[0] ?? "");
    $("#f-tank").textContent = `The amber line starts full at every brim fill, adds the other fills from your log and subtracts each trip's estimated burn (city, highway and idle rates from the Fuel page). The band is ±1.96 posterior SD of the burned litres, so it widens until the next brim fill. Blue dots are the car's own gauge.`
      + (lg ? ` Latest: the gauge read ${lg[2]}% (≈${nf1.format(lg[1])} L) on ${fmtDate(day(lg[0]), { day: "numeric", month: "short" })}, the model ${nf1.format(lp[1])} ± ${nf1.format(z * lp[2])} L. Across ${g.length} reading${g.length === 1 ? "" : "s"} the gauge sits ${nf1.format(Math.abs(mean))} L ${mean >= 0 ? "above" : "below"} the model on average.`
        + " The band covers only the rate uncertainty: a brim fill that isn't truly full or a gauge that isn't linear near the top adds more, so the readings will tune this as they accumulate." : "");
  }

  async function main() {
    try { D = await LB.load("data.json"); }
    catch { LB.fail("Run <code>uv run serve.py</code> from the project folder to build it."); return; }
    LB.run([hero, year, rhythm, commute, traffic, trips, style, car, cost, reminders]);
    LB.initSync(D.generated_at);
  }
  main();
})();
