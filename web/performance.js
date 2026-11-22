/* Performance page: drive-cycle and trip analytics from performance.json (built by performance.py). */
(() => {
  "use strict";
  const { C, SERIES, SEQ, WD, TT, FONT, $, nf, nf1, nf2, pct, fmtDate, fmtTime, clock, esc, axis, chart } = LB;
  let D;

  const FEATURE = { log_km: "Distance (log)", overall_kmh: "Overall speed", idle_share: "Idle share", max_kmh: "Top speed", log_min: "Duration (log)" };
  // Diverging for the dark surface: the extremes are the brightest, the neutral midpoint recedes.
  const BAND_COLORS = ["#3a4556", "#5b3a10", "#8a5a14", "#c97c12", "#f2a33a", "#ffd58a", "#fff1d6"];
  const legend = (o = {}) => ({ top: 0, left: 0, textStyle: { color: C.ink, fontFamily: "Instrument Sans" }, itemWidth: 10, itemHeight: 10, ...o });
  const method = (id, html) => { $(id).innerHTML = html; };
  const shortDate = (s) => fmtDate(s, { day: "numeric", month: "short" });
  const quantiles = (arr) => {
    const a = [...arr].sort((x, y) => x - y);
    const q = (p) => { const i = (a.length - 1) * p, lo = Math.floor(i), hi = Math.ceil(i); return a[lo] + (a[hi] - a[lo]) * (i - lo); };
    const q1 = q(0.25), q3 = q(0.75), iqr = q3 - q1;
    const inside = a.filter((v) => v >= q1 - 1.5 * iqr && v <= q3 + 1.5 * iqr);
    return { box: [inside[0], q1, q(0.5), q3, inside[inside.length - 1]], out: a.filter((v) => v < q1 - 1.5 * iqr || v > q3 + 1.5 * iqr), median: q(0.5) };
  };
  const stat = (n, k, p, flag) => `<div class="stat${flag ? " flag" : ""}"><div class="n">${n}</div><div class="k">${k}</div>${p ? `<p>${p}</p>` : ""}</div>`;

  // ---------- head ----------
  function head() {
    const t = D.totals;
    const prof = D.clusters.profiles;
    const hw = prof.reduce((a, b) => (b.overall_kmh > a.overall_kmh ? b : a));
    const otherTrips = prof.filter((p) => p !== hw).reduce((a, p) => a + p.n, 0);
    $("#h1").textContent = `${pct(otherTrips / t.trips)} of your trips are city driving, but ${hw.name.toLowerCase()} cover ${pct(hw.share_km)} of your kilometres.`;
    $("#lede").textContent = `An engineer's view of ${nf.format(t.trips)} trips and ${nf.format(t.km)} km: how the car is driven, how hard, and how predictably. Distances include the ${nf2.format(D.delta_km_per_trip)} km per trip that Bluelink drops by rounding down.`;
    $("#stats").innerHTML =
      stat(nf.format(t.engine_h) + "<small>h</small>", "Engine hours", `${nf.format(t.idle_h)} h of it idling`) +
      stat(nf1.format(t.km_per_engine_h) + "<small>km/h</small>", "Km per engine hour", "Distance ÷ engine-on time") +
      stat(nf2.format(t.rpa_median) + "<small>m/s²</small>", "Median RPA", "Low-pass estimate, see below") +
      stat(nf2.format(t.stops_per_km_median), "Stops per km", "Median across routed trips") +
      stat(nf.format(t.routed), "Trips with GPS", `of ${nf.format(t.trips)}; drive-cycle metrics use these`);
  }

  // ---------- drive cycle ----------
  function cycle() {
    const city = D.trips.filter((t) => D.clusters.profiles[t.cluster] && D.clusters.profiles[t.cluster].overall_kmh < 30).map((t) => t.overall_kmh);
    const low = D.wltc[0];
    const med = quantiles(city).median;
    $("#f-cycle").textContent = `In town you average ${nf1.format(med)} km/h including stops, ${med < low.avg_kmh ? "slower than" : "about"} the ${nf1.format(low.avg_kmh)} km/h of WLTC's slowest phase.`;
    const series = D.clusters.profiles.map((p, i) => ({
      name: p.name, type: "scatter", symbolSize: 7, itemStyle: { color: SERIES[i], opacity: 0.75, borderColor: C.night, borderWidth: 1 },
      data: D.trips.filter((t) => t.cluster === i).map((t) => [t.overall_kmh, t.max_kmh, t.start_ts, t.km]),
    }));
    series.push({
      name: "WLTC phases", type: "scatter", symbol: "diamond", symbolSize: 16, z: 5,
      itemStyle: { color: C.ink, borderColor: C.night, borderWidth: 2 },
      label: { show: true, position: "right", color: C.ink, fontFamily: "Instrument Sans", formatter: (p) => p.data[2] },
      data: D.wltc.map((w) => [w.avg_kmh, w.max_kmh, w.phase]),
    });
    chart("#c-cycle", {
      legend: legend(), grid: { left: 52, right: 24, top: 44, bottom: 44 },
      tooltip: { ...TT, formatter: (p) => p.seriesName === "WLTC phases"
        ? `<b>WLTC ${p.data[2]}</b><br>average ${p.data[0]} km/h, top ${p.data[1]} km/h`
        : `<b>${p.seriesName}</b><br>${shortDate(p.data[2])}, ${fmtTime(p.data[2])}<br>${nf1.format(p.data[3])} km, average ${nf1.format(p.data[0])} km/h, top ${p.data[1]} km/h` },
      xAxis: axis({ type: "value", name: "Average speed incl. stops (km/h)", nameLocation: "middle", nameGap: 28, splitLine: { show: false } }),
      yAxis: axis({ type: "value", name: "Top speed (km/h)", nameLocation: "middle", nameGap: 38 }),
      series,
    });

    const rows = [{ label: "All GPS trips", share: D.speed_bands.share }]
      .concat(D.bands_by_cluster.map((b) => ({ label: D.clusters.profiles[b.cluster].name, share: b.share })));
    chart("#c-bands", {
      legend: legend({ top: "auto", bottom: 0 }), grid: { left: 110, right: 16, top: 8, bottom: 84 },
      tooltip: { ...TT, trigger: "item", formatter: (p) => `<b>${p.name}</b><br>${p.seriesName} km/h: ${pct(p.value, 1)} of the time` },
      xAxis: axis({ type: "value", max: 1, axisLabel: { ...FONT, formatter: (v) => pct(v) } }),
      yAxis: axis({ type: "category", inverse: true, data: rows.map((r) => r.label), splitLine: { show: false } }),
      series: D.speed_bands.bands.map((b, j) => ({
        name: b, type: "bar", stack: "s", barWidth: 26, data: rows.map((r) => r.share[j]),
        itemStyle: { color: BAND_COLORS[j], borderColor: C.night, borderWidth: 1 },
      })),
    });
    method("#m-cycle", `<p>Overall speed is distance ÷ elapsed time, so idling counts against it, which is how WLTC phase averages are defined too. WLTC class 3b phase values: Low 18.9 / 56.5, Medium 39.5 / 76.6, High 56.7 / 97.4, Extra high 91.7 / 131.3 km/h (average / top). Speed bands are time-weighted over GPS samples (speed derived from consecutive breadcrumbs), routed trips only. "Stopped" is under 5 km/h.</p>`);
  }

  // ---------- dynamics ----------
  function dynamics() {
    const va = D.speed_accel;
    const data = [];
    let max = 0;
    va.seconds.forEach((row, i) => row.forEach((s, j) => { if (s > 0) { const v = Math.log10(s); data.push([i, j, v, s]); max = Math.max(max, v); } }));
    const vLab = va.speed_edges.slice(0, -1).map((v, i) => `${v}–${va.speed_edges[i + 1]}`);
    const aLab = va.acc_edges.slice(0, -1).map((a, i) => `${((a + va.acc_edges[i + 1]) / 2).toFixed(2)}`);
    chart("#c-va", {
      grid: { left: 64, right: 16, top: 12, bottom: 84 },
      tooltip: { ...TT, formatter: (p) => `<b>${vLab[p.data[0]]} km/h</b>, ${va.acc_edges[p.data[1]]} to ${va.acc_edges[p.data[1] + 1]} m/s²<br>${nf1.format(p.data[3] / 60)} min` },
      xAxis: axis({ type: "category", data: vLab, name: "Speed (km/h)", nameLocation: "middle", nameGap: 30, splitLine: { show: false }, axisLabel: { ...FONT, interval: 1 } }),
      yAxis: axis({ type: "category", data: aLab, name: "Acceleration (m/s²)", nameLocation: "middle", nameGap: 46, splitLine: { show: false } }),
      visualMap: { min: 0, max, dimension: 2, orient: "horizontal", left: 64, bottom: 0, itemWidth: 10, itemHeight: 160, calculable: false,
        text: [`${nf.format(10 ** max / 60)} min`, "1 s"], textStyle: { ...FONT }, inRange: { color: SEQ.slice(1) } },
      series: [{ type: "heatmap", data, itemStyle: { borderColor: C.night, borderWidth: 1 } }],
    });

    const prof = D.clusters.profiles;
    const stats = prof.map((p, i) => quantiles(D.trips.filter((t) => t.cluster === i && t.rpa != null).map((t) => t.rpa)));
    const order = stats.map((s, i) => [s.median, i]).filter((x) => !Number.isNaN(x[0])).sort((a, b) => b[0] - a[0]);
    const hi = order[0], lo = order[order.length - 1];
    $("#f-dyn").textContent = `${prof[hi[1]].name} trips work the engine hardest per kilometre: median RPA ${nf2.format(hi[0])} m/s², against ${nf2.format(lo[0])} for ${prof[lo[1]].name.toLowerCase()}.`;
    chart("#c-rpa", {
      grid: { left: 110, right: 16, top: 12, bottom: 40 },
      tooltip: { ...TT, formatter: (p) => p.seriesType === "boxplot"
        ? `<b>${p.name}</b><br>median ${nf2.format(p.data[3])} m/s²<br>IQR ${nf2.format(p.data[2])}–${nf2.format(p.data[4])}`
        : `outlier: ${nf2.format(p.data[0])} m/s²` },
      yAxis: axis({ type: "category", inverse: true, data: prof.map((p) => p.name), splitLine: { show: false } }),
      xAxis: axis({ type: "value", name: "RPA (m/s²)", nameLocation: "middle", nameGap: 26 }),
      series: [
        { type: "boxplot", layout: "horizontal", boxWidth: [12, 26], data: stats.map((s, i) => ({ value: s.box, itemStyle: { color: "rgba(0,0,0,0)", borderColor: SERIES[i], borderWidth: 2 } })) },
        { type: "scatter", symbolSize: 5, itemStyle: { color: C.fog, opacity: 0.6 }, data: stats.flatMap((s, i) => s.out.map((v) => [v, i])) },
      ],
    });
    method("#m-dyn", `<p>Relative positive acceleration, <code>RPA = Σ v·max(a, 0)·Δt ÷ distance</code>, measures how much accelerating a trip needs per metre. Speeds come from the distance between consecutive GPS breadcrumbs, smoothed with a 5-point rolling median.</p>
      <p>Bluelink stamps breadcrumbs only to the minute (about six share a timestamp; their times are spread evenly), so accelerations are heavily low-pass filtered: real peaks are much sharper than shown and RPA is biased low. Use these numbers to compare your own trips with each other, not with published drive-cycle values. Stationary samples (under 2 km/h) are left out of the heatmap.</p>`);
  }

  // ---------- archetypes ----------
  function archetypes() {
    const cl = D.clusters, prof = cl.profiles;
    $("#f-arch").textContent = `Your trips fall into ${prof.length} types: ${prof.map((p) => p.name.toLowerCase()).join(", ").replace(/, ([^,]*)$/, " and $1")}.`;
    $("#l-arch").textContent = prof.map((p) => `${p.name}: ${nf.format(p.n)} trips, ${pct(p.share_km)} of the distance`).join(". ") + ". Plotted on the first two principal components of the clustering features.";
    const ev = cl.explained_variance;
    const pts = D.trips.map((t) => [t.pc1, t.pc2]);
    const reach = Math.max(...pts.map((p) => Math.hypot(p[0], p[1])));
    const scale = reach * 0.55;
    const series = prof.map((p, i) => ({
      name: p.name, type: "scatter", symbolSize: 6, itemStyle: { color: SERIES[i], opacity: 0.7 },
      data: D.trips.filter((t) => t.cluster === i).map((t) => [t.pc1, t.pc2, t.start_ts, t.km, t.overall_kmh]),
    }));
    series.push({
      name: "Feature loadings", type: "lines", coordinateSystem: "cartesian2d", z: 6, silent: true,
      lineStyle: { color: C.ink, width: 1.5, opacity: 0.9 }, symbol: ["none", "arrow"], symbolSize: 7,
      data: Object.entries(cl.loadings).map(([f, l]) => ({ coords: [[0, 0], [l[0] * scale, l[1] * scale]] })),
    });
    series.push({
      name: "Feature labels", type: "scatter", symbolSize: 0, z: 7, silent: true, tooltip: { show: false },
      label: { show: true, color: C.ink, fontFamily: "Instrument Sans", fontSize: 12, formatter: (p) => p.value[2], position: "right" },
      data: (() => {
        // Nearly collinear loadings would print on top of each other: nudge close pairs apart vertically.
        const ends = Object.entries(cl.loadings).map(([f, l]) => ({ x: l[0] * scale * 1.06, y: l[1] * scale * 1.06, name: FEATURE[f] || f, dy: 0 }));
        ends.forEach((a, i) => ends.slice(i + 1).forEach((b) => {
          if (Math.hypot(a.x - b.x, a.y - b.y) < scale * 0.25) { const [hi, lo] = a.y >= b.y ? [a, b] : [b, a]; hi.dy -= 9; lo.dy += 9; }
        }));
        return ends.map((e) => ({ value: [e.x, e.y, e.name], label: { offset: [0, e.dy] } }));
      })(),
    });
    chart("#c-pca", {
      legend: legend({ data: prof.map((p) => p.name) }), grid: { left: 52, right: 90, top: 44, bottom: 44 },
      tooltip: { ...TT, formatter: (p) => `<b>${p.seriesName}</b><br>${shortDate(p.data[2])}, ${fmtTime(p.data[2])}<br>${nf1.format(p.data[3])} km at ${nf1.format(p.data[4])} km/h overall` },
      xAxis: axis({ type: "value", name: `PC1 (${pct(ev[0])} of variance)`, nameLocation: "middle", nameGap: 28, splitLine: { show: false } }),
      yAxis: axis({ type: "value", name: `PC2 (${pct(ev[1])})`, nameLocation: "middle", nameGap: 34 }),
      series,
    });

    const ks = Object.keys(cl.silhouette).map(Number);
    const best = ks.reduce((a, b) => (cl.silhouette[b] > cl.silhouette[a] ? b : a));
    chart("#c-sil", {
      grid: { left: 44, right: 12, top: 16, bottom: 36 },
      tooltip: { ...TT, formatter: (p) => `<b>k = ${p.name}</b><br>silhouette ${nf2.format(p.value)}${+p.name === cl.k ? "<br>used on this page" : ""}` },
      xAxis: axis({ type: "category", data: ks, name: "k", nameLocation: "middle", nameGap: 24 }),
      yAxis: axis({ type: "value", min: 0, splitNumber: 3 }),
      series: [{ type: "bar", barMaxWidth: 34, data: ks.map((k) => ({ value: cl.silhouette[k], itemStyle: { color: k === cl.k ? C.sodium : C.amber, borderRadius: [4, 4, 0, 0] } })),
        label: { show: true, position: "top", color: C.fog, fontFamily: "Instrument Sans", formatter: (p) => nf2.format(p.value) } }],
    });
    $("#n-sil").textContent = best === cl.k
      ? `k = ${cl.k} also has the best silhouette score.`
      : `k = ${best} separates the data more cleanly (${nf2.format(cl.silhouette[best])} against ${nf2.format(cl.silhouette[cl.k])}), mostly by splitting highway runs from everything else. This page uses k = ${cl.k} (highlighted) because it also pulls the short hops apart from stop-and-go traffic, and three is the most groups a chart can colour safely for colour-blind readers.`;

    const cols = [["Trip type", null], ["Trips", "n"], ["Share of km", "share_km"], ["Median km", "km"], ["Median overall km/h", "overall_kmh"],
      ["Median idle share", "idle_share"], ["Median top km/h", "max_kmh"], ["Median minutes", "minutes"]];
    const fmt = (k, v) => k === "share_km" || k === "idle_share" ? pct(v) : k === "n" ? nf.format(v) : nf1.format(v);
    $("#t-clusters").innerHTML = `<thead><tr>${cols.map(([h, k], i) => `<th class="${i ? "num" : ""}">${h}</th>`).join("")}</tr></thead><tbody>` +
      prof.map((p, i) => `<tr><td><span class="swatch" style="background:${SERIES[i]}"></span>${esc(p.name)}</td>${cols.slice(1).map(([, k]) => `<td class="num">${fmt(k, p[k])}</td>`).join("")}</tr>`).join("") + "</tbody>";
    method("#m-arch", `<p>k-means (k = ${cl.k}, 50 restarts) on standardised features: ${cl.features.map((f) => FEATURE[f] || f).join(", ")}. Distance and duration are log-transformed (<code>log1p</code>) so a few long highway trips don't dominate. Names come from rules on the cluster medians, not by hand. The arrows are PCA loadings (component × √eigenvalue), scaled to fit; they show which features push a trip along each axis. PC1 and PC2 together explain ${pct(ev[0] + ev[1])} of the variance.</p>`);
  }

  // ---------- scaling ----------
  function scaling() {
    const pl = D.power_law;
    const mult = 2 ** pl.b;
    $("#f-pl").textContent = `Trip time grows with distance to the power ${nf2.format(pl.b)}: double the distance and the trip takes ${nf2.format(mult)}× as long, not 2×.`;
    const out = new Set(pl.outliers.map((o) => o.id));
    const slow = pl.outliers.filter((o) => o.stud > 0), fast = pl.outliers.filter((o) => o.stud < 0);
    const idleShare = slow.reduce((a, o) => a + o.idle_min, 0) / Math.max(1, slow.reduce((a, o) => a + o.minutes, 0));
    const fastShort = fast.every((o) => o.km < 2);
    $("#l-pl").textContent = `Short trips are slow per kilometre because fixed costs (parking, junctions, signals) dominate. The fit explains ${pct(pl.r2)} of the variance in log time. ${slow.length} trips took far longer than expected, and ${pct(idleShare)} of their time was spent standing still.` +
      (fast.length ? ` ${fast.length} were quicker than predicted${fastShort ? ": all hops of about a kilometre, where Bluelink's whole-kilometre rounding makes the distance least reliable" : ""}.` : "");
    const pts = D.trips.filter((t) => t.km >= 1 && t.elapsed_min >= 2);
    const b = pl.band;
    chart("#c-pl", {
      legend: legend(), grid: { left: 56, right: 24, top: 44, bottom: 48 },
      tooltip: { ...TT, formatter: (p) => p.seriesType === "line" ? `${p.seriesName}: ${nf.format(p.data[1])} min at ${nf1.format(p.data[0])} km`
        : `<b>${shortDate(p.data[2])}, ${fmtTime(p.data[2])}</b><br>${nf1.format(p.data[0])} km in ${nf.format(p.data[1])} min` },
      xAxis: axis({ type: "log", name: "Distance (km, log scale)", nameLocation: "middle", nameGap: 28, splitLine: { show: false }, min: 1,
        max: Math.ceil(Math.max(...pts.map((t) => t.km)) / 100) * 100 }),
      yAxis: axis({ type: "log", name: "Duration (min, log scale)", nameLocation: "middle", nameGap: 40, min: 1 }),
      series: [
        { name: "Trips", type: "scatter", symbolSize: 6, itemStyle: { color: C.amber, opacity: 0.6 },
          data: pts.filter((t) => !out.has(t.trip_id)).map((t) => [t.km, t.elapsed_min, t.start_ts]) },
        { name: "Power-law fit", type: "line", showSymbol: false, lineStyle: { color: C.ink, width: 2 }, data: b.km.map((k, i) => [k, b.fit[i]]) },
        { name: "95% prediction band", type: "line", showSymbol: false, lineStyle: { color: C.fog, width: 1.5, type: "dashed" }, data: b.km.map((k, i) => [k, b.hi[i]]) },
        { name: "95% prediction band", type: "line", showSymbol: false, lineStyle: { color: C.fog, width: 1.5, type: "dashed" }, data: b.km.map((k, i) => [k, b.lo[i]]) },
        { name: "Outliers", type: "scatter", symbolSize: 9, itemStyle: { color: C.tail, borderColor: C.night, borderWidth: 1.5 },
          label: { show: true, position: "right", color: C.ink, fontFamily: "Instrument Sans", fontSize: 11, formatter: (p) => shortDate(p.data[2]) },
          labelLayout: { hideOverlap: true },
          data: pl.outliers.map((o) => [o.km, o.minutes, o.start]) },
      ],
    });
    $("#t-outliers").innerHTML = `<thead><tr><th>Trip</th><th class="num">Km</th><th class="num">Minutes</th><th class="num">Expected</th><th class="num">Idling</th><th class="num">Std. residual</th></tr></thead><tbody>` +
      pl.outliers.map((o) => `<tr class="${o.stud > 0 ? "" : ""}"><td>${fmtDate(o.start, { weekday: "short", day: "numeric", month: "short" })}, ${fmtTime(o.start)}</td>
        <td class="num">${nf1.format(o.km)}</td><td class="num">${nf.format(o.minutes)}</td><td class="num">${nf.format(o.expected)}</td>
        <td class="num">${nf.format(o.idle_min)} min</td><td class="num">${o.stud > 0 ? "+" : ""}${nf2.format(o.stud)}</td></tr>`).join("") + "</tbody>";
    method("#m-pl", `<p>Ordinary least squares on <code>log(minutes) = a + b·log(km)</code> over ${nf.format(pl.n)} trips of at least 1 km and 2 minutes: a = ${nf2.format(pl.a)}, b = ${nf2.format(pl.b)}, residual s = ${nf2.format(pl.s)} (log units), so minutes ≈ ${nf1.format(Math.exp(pl.a))} × km<sup>${nf2.format(pl.b)}</sup>. The band is the 95% prediction interval for a new trip, <code>±1.96·s·√(1 + h)</code> with leverage h. Outliers have an internally studentised residual beyond ±2.5.</p>`);
  }

  // ---------- commute ----------
  function commute() {
    const cm = D.commute;
    if (!cm || !cm.to_work || !cm.to_home) {
      $("#f-com").textContent = "Commute reliability appears once home and work each have enough trips.";
      $("#commute").querySelectorAll(".grid-3, details").forEach((n) => n.remove());
      return;
    }
    const w = cm.to_work, h = cm.to_home;
    const worse = h.pti >= w.pti ? ["home", h] : ["to work", w];
    $("#f-com").textContent = `To arrive on time 19 days in 20, allow ${nf.format(worse[1].p95)} min for the drive ${worse[0]}, even though it usually takes ${nf.format(worse[1].median)}.`;
    $("#l-com").textContent = `Same ${nf1.format(w.km)} km each way. The morning drive is the slower one on a typical day; the evening drive is the less predictable one.`;
    $("#s-com").innerHTML =
      stat(`${nf.format(w.median)}<small>min</small>`, "To work, typical", `free-flow ${nf.format(w.free_flow)} min, ${w.n} drives`) +
      stat(nf2.format(w.pti), "To work, planning time index", `buffer index ${nf2.format(w.bti)}`) +
      stat(`${nf.format(h.median)}<small>min</small>`, "Home, typical", `free-flow ${nf.format(h.free_flow)} min, ${h.n} drives`) +
      stat(nf2.format(h.pti), "Home, planning time index", `buffer index ${nf2.format(h.bti)}`);

    const dirs = [["To work", w, SERIES[0]], ["Home", h, SERIES[1]]];
    const qs = dirs.map(([, d]) => quantiles(d.minutes));
    chart("#c-com-box", {
      grid: { left: 64, right: 16, top: 12, bottom: 36 },
      tooltip: { ...TT, formatter: (p) => p.seriesType === "boxplot"
        ? `<b>${p.name}</b><br>median ${nf.format(p.data[3])} min<br>IQR ${nf.format(p.data[2])}–${nf.format(p.data[4])} min` : `${nf.format(p.data[0])} min` },
      yAxis: axis({ type: "category", inverse: true, data: dirs.map((d) => d[0]), splitLine: { show: false } }),
      xAxis: axis({ type: "value", name: "minutes", nameLocation: "middle", nameGap: 24 }),
      series: [
        { type: "boxplot", layout: "horizontal", boxWidth: [14, 30], data: qs.map((q, i) => ({ value: q.box, itemStyle: { color: "rgba(0,0,0,0)", borderColor: dirs[i][2], borderWidth: 2 } })) },
        { type: "scatter", symbolSize: 6, itemStyle: { color: C.fog }, data: qs.flatMap((q, i) => q.out.map((v) => [v, i])) },
      ],
    });

    const errSeries = (name, d, color) => [
      { name, type: "line", data: d.by_slot.map((s) => [s[0], s[1], s[2]]), lineStyle: { color, width: 2 }, itemStyle: { color }, symbolSize: 7 },
      { name, type: "custom", silent: true, data: d.by_slot.map((s) => [s[0], s[3], s[4]]),
        renderItem: (params, api) => {
          const a = api.coord([api.value(0), api.value(1)]), b = api.coord([api.value(0), api.value(2)]);
          return { type: "line", shape: { x1: a[0], y1: a[1], x2: b[0], y2: b[1] }, style: { stroke: color, lineWidth: 6, opacity: 0.35, lineCap: "round" } };
        } },
    ];
    chart("#c-com-slot", {
      legend: legend({ data: ["To work", "Home"] }), grid: { left: 56, right: 12, top: 36, bottom: 36 },
      tooltip: { ...TT, formatter: (p) => p.seriesType === "line" ? `<b>${p.seriesName}</b>, leaving ${clock(p.data[0])}<br>median ${nf.format(p.data[1])} min (${p.data[2]} drives)` : "" },
      xAxis: axis({ type: "value", min: (v) => Math.floor(v.min), max: (v) => Math.ceil(v.max + 0.25), splitLine: { show: false },
        axisLabel: { ...FONT, formatter: (v) => (Number.isInteger(v) ? clock(v).replace(":00", "") : "") } }),
      yAxis: axis({ type: "value", splitNumber: 4, axisLabel: { ...FONT, formatter: "{value} min" } }),
      series: [...errSeries("To work", w, SERIES[0]), ...errSeries("Home", h, SERIES[1])],
    });

    const wdIdx = [...new Set([...w.by_weekday, ...h.by_weekday].map((x) => x[0]))].sort();
    const val = (d, i) => (d.by_weekday.find((x) => x[0] === i) || [])[1] ?? null;
    chart("#c-com-wd", {
      legend: legend(), grid: { left: 56, right: 12, top: 36, bottom: 28 },
      tooltip: { ...TT, trigger: "axis", axisPointer: { type: "shadow", shadowStyle: { color: "rgba(156,180,214,0.06)" } },
        formatter: (ps) => `<b>${WD[wdIdx[ps[0].dataIndex]]}</b>` + ps.map((p) => p.value == null ? "" : `<br>${p.seriesName}: ${nf.format(p.value)} min`).join("") },
      xAxis: axis({ type: "category", data: wdIdx.map((i) => WD[i].slice(0, 3)) }),
      yAxis: axis({ type: "value", splitNumber: 4, axisLabel: { ...FONT, formatter: "{value} min" } }),
      series: dirs.map(([name, d, color]) => ({ name, type: "bar", barGap: "12%", barMaxWidth: 18, itemStyle: { color, borderRadius: [3, 3, 0, 0] }, data: wdIdx.map((i) => val(d, i)) })),
    });
    method("#m-com", `<p>Commutes are routed trips from the inferred Home cell to the Work cell (and back), ~150 m grid. Free-flow time is the 5th percentile. <code>Planning time index = p95 ÷ free-flow</code>: how much longer than an empty road you must allow to be on time 95% of the time. <code>Buffer index = (p95 − mean) ÷ mean</code>: the extra time on top of an average day. Departure slots are 15 minutes wide; slots with fewer than 2 drives are dropped. Bars around each point span the inter-quartile range.</p>`);
  }

  // ---------- cold starts ----------
  function cold() {
    const c = D.cold;
    $("#f-cold").textContent = `${pct(c.cold_share)} of your trips start with a cold engine, and ${nf.format(c.short_cold)} of them are over within 5 km.`;
    $("#l-cold").textContent = `A petrol engine runs rich until it warms up, and a short trip after a long park never gets there. Bars from ${c.threshold_h} hours up count as cold starts.`;
    const coldIdx = c.labels.findIndex((l) => l.startsWith(`${c.threshold_h}`));
    chart("#c-soak", {
      grid: { left: 44, right: 12, top: 16, bottom: 32 },
      tooltip: { ...TT, formatter: (p) => `<b>Parked ${p.name}</b><br>${p.value} trips${p.dataIndex >= coldIdx ? "<br>cold start" : ""}` },
      xAxis: axis({ type: "category", data: c.labels }),
      yAxis: axis({ type: "value", splitNumber: 3 }),
      series: [{ type: "bar", barCategoryGap: "18%", data: c.counts.map((v, i) => ({ value: v, itemStyle: { color: i >= coldIdx ? C.sodium : C.amber, borderRadius: [4, 4, 0, 0] } })) }],
    });
    $("#s-cold").innerHTML =
      stat(pct(c.cold_share), "Cold starts", `parked at least ${c.threshold_h} hours before`) +
      stat(nf.format(c.short_cold), "Short cold trips", `${pct(c.short_cold_share)} of all trips end within 5 km of a cold start`) +
      stat(`${nf.format(c.short_cold_km)}<small>km</small>`, "Driven on them", "kilometres on a cold engine, start to finish");
    method("#m-cold", `<p>Soak time is the gap between one trip's end and the next one's start. The first trip on record has no predecessor and counts as cold. ${c.threshold_h} hours is a conservative threshold for a fully cooled engine; coolant temperature isn't available from Bluelink, so this is a proxy.</p>`);
  }

  // ---------- correlations ----------
  function corr() {
    const { labels, matrix } = D.correlations;
    let best = [0, 0, 0];
    matrix.forEach((r, i) => r.forEach((v, j) => {
      if (j <= i || v == null) return;
      const pair = [labels[i], labels[j]];
      const trivial = pair.includes("Distance") && pair.includes("Duration");
      if (!trivial && Math.abs(v) > Math.abs(best[2])) best = [i, j, v];
    }));
    $("#f-corr").textContent = `${labels[best[0]]} and ${labels[best[1]].toLowerCase()} move together most strongly (ρ = ${nf2.format(best[2])}).`;
    const di = labels.indexOf("Distance"), du = labels.indexOf("Duration");
    if (di >= 0 && du >= 0) {
      $("#f-corr-lede").textContent = `Spearman rank correlation between trip features, across every trip on record. `
        + `The headline leaves out distance and duration (ρ = ${nf2.format(matrix[di][du])}): longer trips taking longer isn't news.`;
    }
    const data = [];
    matrix.forEach((r, i) => r.forEach((v, j) => data.push([j, i, i === j ? null : v])));
    chart("#c-corr", {
      grid: { left: 110, right: 16, top: 12, bottom: 96 },
      tooltip: { ...TT, formatter: (p) => `<b>${labels[p.data[1]]} × ${labels[p.data[0]]}</b><br>ρ = ${p.data[2] == null ? "n/a" : nf2.format(p.data[2])}` },
      xAxis: axis({ type: "category", data: labels, splitLine: { show: false }, axisLabel: { ...FONT, rotate: 40 } }),
      yAxis: axis({ type: "category", data: labels, inverse: true, splitLine: { show: false } }),
      visualMap: { min: -1, max: 1, orient: "horizontal", left: 110, bottom: 0, itemWidth: 10, itemHeight: 160, calculable: false,
        text: ["+1", "−1"], textStyle: { ...FONT }, inRange: { color: LB.DIV } },
      series: [{ type: "heatmap", data, itemStyle: { borderColor: C.night, borderWidth: 2 },
        label: { show: true, fontFamily: "Instrument Sans", fontSize: 11, formatter: (p) => (p.data[2] == null ? "" : p.data[2].toFixed(2)),
          color: C.ink, textBorderColor: "rgba(15,26,42,0.6)", textBorderWidth: 2 } }],
    });
    method("#m-corr", `<p>Spearman rank correlation, so monotone but non-linear relations (speed vs distance) still register and outliers have limited pull. Soak time is missing for the first trip. "Overall speed" includes idling, "moving speed" (Bluelink's figure) excludes it. Correlation across trips, not causation: long trips are also highway trips.</p>`);
  }

  // ---------- forecast ----------
  function forecast() {
    const f = D.forecast;
    const ms = f.milestones[0];
    $("#f-fc").textContent = ms
      ? `At ${nf.format(f.km_per_day)} km a day, you'll pass ${nf.format(ms.km)} km around ${fmtDate(ms.p50, { day: "numeric", month: "long", year: "numeric" })}.`
      : `You're averaging ${nf.format(f.km_per_day)} km a day.`;
    $("#l-fc").textContent = ms
      ? `80% interval: ${fmtDate(ms.early, { day: "numeric", month: "short" })} to ${ms.late ? fmtDate(ms.late, { day: "numeric", month: "short", year: "numeric" }) : "after the forecast window"}. Based on the last ${f.window_days} days, where daily distance varied a lot (standard deviation ${nf.format(f.sd_per_day)} km).`
      : "";
    const hist = f.history.map((d) => [d[0], d[1]]);
    const fut = f.future;
    chart("#c-fc", {
      legend: legend({ data: ["Odometer", "Forecast", "80% interval"] }), grid: { left: 64, right: 24, top: 44, bottom: 36 },
      tooltip: { ...TT, trigger: "axis", formatter: (ps) => {
        const p = ps.find((x) => x.seriesName === "Odometer" || x.seriesName === "Forecast");
        if (!p) return "";
        const d = fmtDate(p.data[0], { day: "numeric", month: "short", year: "numeric" });
        if (p.seriesName === "Odometer") return `<b>${d}</b><br>${nf.format(p.data[1])} km`;
        const row = fut.find((x) => x[0] === p.data[0]);
        return `<b>${d}</b><br>forecast ${nf.format(row[1])} km<br>80%: ${nf.format(row[2])}–${nf.format(row[3])} km`;
      } },
      xAxis: axis({ type: "time", splitLine: { show: false } }),
      yAxis: axis({ type: "value", scale: true, axisLabel: { ...FONT, formatter: (v) => nf.format(v) } }),
      series: [
        { name: "80% interval", type: "line", stack: "band", showSymbol: false, lineStyle: { opacity: 0 }, itemStyle: { color: "rgba(242,163,58,0.4)" }, data: fut.map((d) => [d[0], d[2]]), tooltip: { show: false } },
        { name: "80% interval", type: "line", stack: "band", showSymbol: false, lineStyle: { opacity: 0 }, areaStyle: { color: "rgba(242,163,58,0.18)" },
          itemStyle: { color: "rgba(242,163,58,0.4)" }, data: fut.map((d) => [d[0], d[3] - d[2]]) },
        { name: "Odometer", type: "line", showSymbol: false, lineStyle: { color: C.amber, width: 2 }, itemStyle: { color: C.amber }, data: hist },
        { name: "Forecast", type: "line", showSymbol: false, lineStyle: { color: C.sodium, width: 2, type: "dashed" }, itemStyle: { color: C.sodium },
          data: fut.map((d) => [d[0], d[1]]),
          markLine: { symbol: "none", silent: true, lineStyle: { color: C.fog, type: "dotted" },
            label: { color: C.ink, fontFamily: "Instrument Sans", formatter: (p) => p.data.name },
            data: f.milestones.filter((m) => m.p50).map((m) => ({ xAxis: m.p50, name: `${nf.format(m.km)} km, ${fmtDate(m.p50, { month: "short", year: "numeric" })}` })) } },
      ],
    });
    const wk = f.weekly;
    const roll = wk.map((_, i) => { const s = wk.slice(Math.max(0, i - 3), i + 1); return s.reduce((a, x) => a + x[1], 0) / s.length; });
    chart("#c-weekly", {
      legend: legend(), grid: { left: 52, right: 16, top: 36, bottom: 28 },
      tooltip: { ...TT, trigger: "axis", formatter: (ps) => `<b>Week of ${fmtDate(wk[ps[0].dataIndex][0], { day: "numeric", month: "short" })}</b>` + ps.map((p) => `<br>${p.seriesName}: ${nf.format(p.value)} km`).join("") },
      xAxis: axis({ type: "category", data: wk.map((w) => fmtDate(w[0], { day: "numeric", month: "short" })) }),
      yAxis: axis({ type: "value", splitNumber: 3 }),
      series: [
        { name: "Weekly km", type: "bar", barCategoryGap: "20%", itemStyle: { color: C.amber, borderRadius: [3, 3, 0, 0] }, data: wk.map((w) => w[1]) },
        { name: "4-week rolling mean", type: "line", showSymbol: false, lineStyle: { color: C.beam, width: 2 }, itemStyle: { color: C.beam }, data: roll },
      ],
    });
    method("#m-fc", `<p>Daily distance over the last ${f.window_days} days is treated as independent draws with mean μ = ${nf1.format(f.km_per_day)} km and standard deviation σ = ${nf1.format(f.sd_per_day)} km. After h days the odometer is forecast at <code>now + μh</code> with variance <code>hσ² + (hσ/√n)²</code>, the second term for uncertainty in μ; bands are the normal 10th–90th percentiles. Weekly travel is bursty (road trips), so the interval is wide on purpose. The history line is the odometer rebuilt backwards from today's reading.</p>`);
  }

  // ---------- trends ----------
  function trends() {
    const m = D.monthly;
    const worst = m.reduce((a, b) => (b.idle_share > a.idle_share ? b : a));
    const best = m.reduce((a, b) => (b.idle_share < a.idle_share ? b : a));
    const mName = (s) => fmtDate(s + "-01", { month: "long", year: "numeric" });
    $("#f-trend").textContent = `Traffic was worst in ${mName(worst.month)}: a typical trip spent ${pct(worst.idle_share)} of its time standing still, against ${pct(best.idle_share)} in ${mName(best.month)}.`;
    const months = m.map((r) => fmtDate(r.month + "-01", { month: "short" }));
    const small = (el, name, values, fmt, type = "line") => chart(el, {
      grid: { left: 48, right: 12, top: 12, bottom: 24 },
      tooltip: { ...TT, trigger: "axis", formatter: (ps) => `<b>${mName(m[ps[0].dataIndex].month)}</b><br>${name}: ${fmt(ps[0].value)}` },
      xAxis: axis({ type: "category", data: months, boundaryGap: type === "bar" }),
      yAxis: axis({ type: "value", splitNumber: 3, scale: type === "line", axisLabel: { ...FONT, formatter: fmt } }),
      series: [type === "bar"
        ? { type: "bar", barMaxWidth: 22, itemStyle: { color: C.amber, borderRadius: [3, 3, 0, 0] }, data: values }
        : { type: "line", data: values, symbolSize: 6, lineStyle: { color: C.amber, width: 2 }, itemStyle: { color: C.amber } }],
    });
    small("#c-m1", "Median moving speed", m.map((r) => r.moving_kmh), (v) => `${nf.format(v)}`);
    small("#c-m2", "Median idle share", m.map((r) => r.idle_share), (v) => pct(v));
    small("#c-m3", "Engine hours", m.map((r) => r.engine_h), (v) => nf.format(v), "bar");
    small("#c-m4", "Alerts per 1,000 km", m.map((r) => (r.km ? (r.events / r.km) * 1000 : 0)), (v) => nf1.format(v), "bar");
  }

  async function main() {
    try { D = await LB.load("performance.json"); }
    catch { LB.fail("Run <code>uv run serve.py</code> from the project folder to build it."); return; }
    LB.run([head, cycle, dynamics, archetypes, scaling, commute, cold, corr, forecast, trends]);
    $("#foot").textContent = `Built from your Bluelink archive, stored only on this Mac. Last rebuilt ${fmtDate(D.generated_at, { day: "numeric", month: "short" })}, ${fmtTime(D.generated_at)}.`;
    LB.initSync(D.generated_at);
  }
  main();
})();
