/* Fuel page. Reads fuel.json (built by fuel.py via insights.py). */
(() => {
  "use strict";
  const { C, TT, FONT, $, nf, nf1, nf2, rupees, pct, day, fmtDate, esc, axis, chart } = LB;
  let F;

  const short = (s) => fmtDate(s, { day: "numeric", month: "short" });
  const long = (s) => fmtDate(s, { day: "numeric", month: "short", year: "numeric" });
  const monthName = (m) => fmtDate(m + "-01", { month: "short", year: "2-digit" });
  const stat = (n, unit, k, p, flag) =>
    `<div class="stat${flag ? " flag" : ""}"><div class="n">${n}${unit ? `<small>${unit}</small>` : ""}</div><div class="k">${k}</div>${p ? `<p>${p}</p>` : ""}</div>`;
  const legend = (o = {}) => ({ top: 0, right: 0, textStyle: { color: C.ink, fontFamily: "Instrument Sans" }, itemWidth: 12, itemHeight: 10, ...o });
  const COEF = {
    city_l100: { label: "City", unit: "L/100 km", kmpl: (v) => 100 / v },
    hwy_l100: { label: "Highway", unit: "L/100 km", kmpl: (v) => 100 / v },
    idle_lph: { label: "Idle", unit: "L/h", kmpl: null },
  };

  // ---------- header ----------
  function head() {
    const t = F.totals;
    $("#h-main").textContent = `You get ${nf1.format(t.kmpl_valid)} km/L. City driving is ${pct(t.city_share_km)} of your distance but ${pct(t.city_share_fuel)} of your fuel.`;
    $("#h-lede").textContent = `Built from ${t.fills} fill-ups you logged between ${long(t.first_fill)} and ${long(t.last_fill)}, matched against every trip Bluelink recorded. Economy comes from the stretches between fill-ups, and a small Bayesian model splits it into city, highway and idling.`;
    $("#h-stats").innerHTML =
      stat(nf1.format(t.kmpl_valid), "km/L", "Fuel economy", `Over ${nf.format(t.km_valid)} km of clean fill-to-fill stretches`) +
      stat("₹" + nf2.format(t.rs_per_km_model), "/km", "Fuel cost per km", `At the prices you actually paid`) +
      stat(rupees(t.spend), "", "Spent on fuel", `${nf.format(t.litres)} L at ${rupees(t.avg_rate)}/L on average`) +
      stat(rupees(t.idle_cost), "", "Burned standing still", `${nf.format(t.idle_l)} L, ${pct(t.idle_share_of_fuel)} of all fuel`);
  }

  // ---------- calibration ----------
  function calibration() {
    const c = F.calibration;
    const pts = c.points;
    const maxRaw = Math.max(...pts.map((p) => p.rebuilt_raw - p.logged_km));
    $("#h-cal").textContent = `Bluelink drops about ${nf.format(c.delta * 1000)} m from every trip. Corrected, the rebuilt odometer matches your log with a typical error of ${nf1.format(c.resid_sd)} km.`;
    $("#l-cal").textContent = `Adding up trip distances backwards from today's odometer should reproduce the readings you wrote down at the pump. Uncorrected, it drifts up to ${nf.format(maxRaw)} km off, and the drift grows with the number of trips in between: each trip's distance is rounded down to a whole kilometre.`;
    chart("#c-cal", {
      grid: { left: 64, right: 16, top: 40, bottom: 32 },
      legend: legend({ data: ["As Bluelink reports trips", "With per-trip correction"] }),
      tooltip: { ...TT, trigger: "axis", formatter: (ps) => {
        const p = pts[ps[0].dataIndex];
        return `<b>${long(p.date)}</b><br>You logged ${nf.format(p.logged_km)} km<br>Rebuilt, as reported: ${nf.format(p.rebuilt_raw)} km (${p.rebuilt_raw - p.logged_km >= 0 ? "+" : ""}${nf.format(p.rebuilt_raw - p.logged_km)})<br>Rebuilt, corrected: ${nf.format(p.rebuilt)} km (${p.resid >= 0 ? "+" : ""}${nf1.format(p.resid)})<br>${nf.format(p.trips_after)} trips between then and now`;
      } },
      xAxis: axis({ type: "category", data: pts.map((p) => short(p.date)), splitLine: { show: false }, boundaryGap: false }),
      yAxis: axis({ type: "value", name: "rebuilt − logged (km)", nameLocation: "middle", nameGap: 46 }),
      series: [
        { name: "As Bluelink reports trips", type: "line", data: pts.map((p) => +(p.rebuilt_raw - p.logged_km).toFixed(1)),
          lineStyle: { color: C.amber, width: 2 }, itemStyle: { color: C.amber }, symbolSize: 7 },
        { name: "With per-trip correction", type: "line", data: pts.map((p) => +p.resid.toFixed(1)),
          lineStyle: { color: C.beam, width: 2 }, itemStyle: { color: C.beam }, symbolSize: 7,
          markLine: { silent: true, symbol: "none", lineStyle: { color: C.fog, type: "dashed" }, label: { show: false }, data: [{ yAxis: 0 }] } },
      ],
    });
    $("#s-cal").innerHTML =
      stat(nf2.format(c.delta), "km", "Lost per trip", "Estimated from your log. Pure round-down of random fractions would be 0.5 km; short trips pull it lower.") +
      stat(nf1.format(c.resid_sd), "km", "Residual spread", `Standard deviation over ${c.n} logged readings after correction`);
    $("#m-cal").innerHTML = `<p>For a fill at moment <code>m</code>, the rebuilt odometer is <code>odo_now − Σ d_i − δ·N</code>, summing the reported distances <code>d_i</code> of the <code>N</code> trips that started after <code>m</code>. The fuel log has dates but not times, so each logged fill snaps to the trip boundary that day (before any trip, between trips, or after the last) that best matches the reading.</p>
      <p>Snapping depends on <code>δ</code> and <code>δ</code> depends on snapping, so the two alternate: snap every fill, fit <code>δ</code> by least squares through the origin on <code>gap = δ·N</code>, and repeat until <code>δ</code> stops moving. It converges in a few iterations to δ = ${nf2.format(c.delta)} km per trip. Every downstream number on this site (distance totals, fill-to-fill kilometres) uses the corrected odometer.</p>`;
  }

  // ---------- fills ----------
  function fills() {
    const fl = F.fills, k = F.constants, t = F.totals;
    const over = fl.filter((f) => f.over_tank);
    const maxFill = Math.max(...fl.map((f) => f.litres));
    $("#h-fills").textContent = over.length
      ? `${over.length} fill-ups went past the ${nf.format(k.tank_l)} L tank rating. Your usable tank holds at least ${nf.format(Math.floor(maxFill))} L.`
      : `Your fill-ups, one by one.`;
    $("#l-fills").textContent = `A fill of at least ${nf.format(k.brim_l)} L counts as filling to the brim; smaller ones are top-ups. Going past the rated capacity is normal when the tank is run low: the filler neck and the reserve below the gauge's "empty" hold a few more litres.`;
    const brim = fl.map((f) => [f.date, f.brim ? f.litres : null]);
    const part = fl.map((f) => [f.date, f.brim ? null : f.litres]);
    const imputedNote = { litres: "litres worked out from the amount paid", rate: "rate worked out from the amount and litres", amount: "amount worked out from litres and rate" };
    const tip = (f) => `<b>${long(f.date)}</b>, ${esc(f.station)}<br>${f.litres == null ? "unknown litres" : `${nf2.format(f.litres)} L`} for ${f.amount == null ? "unknown amount" : rupees(f.amount)}${f.rate == null ? "" : ` at ₹${nf2.format(f.rate)}/L`}<br>${esc(f.brand)}${f.premium ? ", premium petrol" : ""}${f.odo != null ? `<br>Odometer ≈ ${nf.format(f.odo)} km` : ""}${f.imputed ? `<br><i>${imputedNote[f.imputed] ?? f.imputed + " estimated"}</i>` : ""}`;
    chart("#c-litres", {
      grid: { left: 48, right: 104, top: 40, bottom: 32 },
      legend: legend({ data: ["Brim fill", "Top-up"] }),
      tooltip: { ...TT, trigger: "item", formatter: (p) => tip(fl[p.dataIndex]) },
      xAxis: axis({ type: "time", splitLine: { show: false } }),
      yAxis: axis({ type: "value", name: "litres", max: Math.ceil(maxFill / 5) * 5 + 5 }),
      series: [
        { name: "Brim fill", type: "bar", stack: "f", barWidth: 9, data: brim, itemStyle: { color: C.amber, borderRadius: [3, 3, 0, 0] },
          label: { show: true, position: "top", color: C.ink, fontFamily: "Instrument Sans", fontSize: 11,
            formatter: (p) => (fl[p.dataIndex].over_tank ? nf1.format(fl[p.dataIndex].litres) : "") },
          markLine: { silent: true, symbol: "none", data: [{ yAxis: k.tank_l }],
            lineStyle: { color: C.fog, type: "dashed" }, label: { color: C.fog, fontFamily: "Instrument Sans", formatter: `${k.tank_l} L rated`, position: "end" } } },
        { name: "Top-up", type: "bar", stack: "f", barWidth: 9, data: part, itemStyle: { color: C.beam, borderRadius: [3, 3, 0, 0] } },
      ],
    });

    const reg = fl.filter((f) => !f.premium), prem = fl.filter((f) => f.premium);
    chart("#c-rate", {
      grid: { left: 48, right: 16, top: 40, bottom: 32 },
      legend: legend({ data: ["Regular petrol", "Premium petrol"] }),
      tooltip: { ...TT, trigger: "item", formatter: (p) => tip((p.seriesIndex ? prem : reg)[p.dataIndex]) },
      xAxis: axis({ type: "time", splitLine: { show: false } }),
      yAxis: axis({ type: "value", scale: true, axisLabel: { ...FONT, formatter: "₹{value}" } }),
      series: [
        { name: "Regular petrol", type: "scatter", symbolSize: 10, data: reg.map((f) => [f.date, f.rate]),
          itemStyle: { color: C.amber, borderColor: C.night, borderWidth: 2 } },
        { name: "Premium petrol", type: "scatter", symbol: "diamond", symbolSize: 13, data: prem.map((f) => [f.date, f.rate]),
          itemStyle: { color: C.beam, borderColor: C.night, borderWidth: 2 },
          label: { show: true, position: "right", color: C.ink, fontFamily: "Instrument Sans", fontSize: 11, formatter: (p) => `₹${nf2.format(p.data[1])}` } },
      ],
    });
    const t0 = day(reg[0].date), t1 = day(reg[reg.length - 1].date);
    const med = (xs) => { const v = xs.map((f) => f.rate).sort((a, b) => a - b); return v[Math.floor(v.length / 2)]; };
    const early = reg.filter((f) => day(f.date) - t0 <= 120 * 864e5), late = reg.filter((f) => t1 - day(f.date) <= 120 * 864e5);
    $("#n-rate").textContent = `Regular petrol cost a median ₹${nf2.format(med(early))}/L in your first four months and ₹${nf2.format(med(late))}/L in the last four. Within any month, the state you fill up in moves the price more than the brand does.` +
      (prem.length ? ` ${prem.length} premium fill${prem.length > 1 ? "s" : ""} cost ${rupees(t.premium_extra)} more than regular would have.` : "");

    const tbl = F.brands.slice().sort((a, b) => b.litres - a.litres);
    $("#t-brands").innerHTML = `<thead><tr><th>Brand</th><th class="num">Fills</th><th class="num">Litres</th><th class="num">Spent</th><th class="num">Median ₹/L</th></tr></thead><tbody>` +
      tbl.map((b) => `<tr><td>${esc(b.brand === "Unknown" ? "Not recorded" : b.brand)}</td><td class="num">${b.fills}</td><td class="num">${nf.format(b.litres)}</td><td class="num">${rupees(b.spend)}</td><td class="num">₹${nf2.format(b.rate)}</td></tr>`).join("") + "</tbody>";
  }

  // ---------- fill-to-fill economy ----------
  function economy() {
    const iv = F.intervals, k = F.constants, t = F.totals;
    const ok = iv.filter((i) => i.status === "ok"), bad = iv.filter((i) => i.status !== "ok");
    $("#h-econ").textContent = bad.length
      ? `Fill to fill, you average ${nf1.format(t.kmpl_valid)} km/L. ${bad.length === 1 ? "One stretch beats" : `${bad.length} stretches beat`} the ${nf2.format(k.arai_kmpl)} km/L rating, so a fill-up is missing from the log.`
      : `Fill to fill, you average ${nf1.format(t.kmpl_valid)} km/L.`;
    $("#l-econ").textContent = `Each bar is the distance between two brim fills divided by everything you bought in between. No real-world drive beats the car's type-approval figure, so stretches above it can only mean fuel that went unlogged. The thin bright line is your average across the clean stretches.`;
    chart("#c-intervals", {
      grid: { left: 48, right: 16, top: 40, bottom: 40 },
      legend: legend({ data: ["Clean stretch", "Fill-up missing from log"] }),
      tooltip: { ...TT, trigger: "item", formatter: (p) => {
        const i = iv[p.dataIndex];
        return `<b>${long(i.from)} to ${long(i.to)}</b><br>${nf.format(i.km)} km on ${nf1.format(i.litres)} L = ${nf1.format(i.kmpl)} km/L<br>${pct(i.hwy_share)} highway, ${nf1.format(i.idle_h)} h idling, ${i.trips} trips${i.status !== "ok" ? "<br><b>Above the type-approval figure: unlogged fill</b>" : ""}`;
      } },
      xAxis: axis({ type: "category", data: iv.map((i) => short(i.to)), splitLine: { show: false }, axisLabel: { ...FONT, hideOverlap: true } }),
      yAxis: axis({ type: "value", name: "km/L" }),
      series: [
        { name: "Clean stretch", type: "bar", stack: "k", barMaxWidth: 26, data: iv.map((i) => (i.status === "ok" ? +i.kmpl.toFixed(2) : null)),
          itemStyle: { color: C.amber, borderRadius: [4, 4, 0, 0] },
          markLine: { silent: true, symbol: "none", data: [
            { yAxis: k.arai_kmpl, lineStyle: { color: C.fog, type: "dashed" }, label: { color: C.fog, fontFamily: "Instrument Sans", formatter: `${nf2.format(k.arai_kmpl)} km/L rating`, position: "insideEndTop" } },
            { yAxis: t.kmpl_valid, lineStyle: { color: C.sodium, type: "solid", width: 1 }, label: { show: false } },
          ] } },
        { name: "Fill-up missing from log", type: "bar", stack: "k", barMaxWidth: 26, data: iv.map((i) => (i.status === "ok" ? null : +i.kmpl.toFixed(2))),
          itemStyle: { color: C.tail, borderRadius: [4, 4, 0, 0] },
          label: { show: true, position: "top", color: C.tail, fontFamily: "Instrument Sans", fontSize: 11, formatter: "missing fill" } },
      ],
    });

    // OLS of km/L on highway share over the clean stretches.
    const xs = ok.map((i) => i.hwy_share), ys = ok.map((i) => i.kmpl);
    const mx = xs.reduce((a, b) => a + b, 0) / xs.length, my = ys.reduce((a, b) => a + b, 0) / ys.length;
    const sxy = xs.reduce((a, x, j) => a + (x - mx) * (ys[j] - my), 0), sxx = xs.reduce((a, x) => a + (x - mx) ** 2, 0);
    const b1 = sxy / sxx, b0 = my - b1 * mx;
    const syy = ys.reduce((a, y) => a + (y - my) ** 2, 0);
    const r = sxy / Math.sqrt(sxx * syy);
    chart("#c-hwy", {
      grid: { left: 48, right: 16, top: 40, bottom: 40 },
      legend: legend({ data: ["Clean stretch", "Least-squares fit"] }),
      tooltip: { ...TT, trigger: "item", formatter: (p) => {
        if (p.seriesIndex === 1) return `Fit: ${nf1.format(b0)} + ${nf1.format(b1)} × highway share`;
        const i = ok[p.dataIndex];
        return `<b>${long(i.from)} to ${long(i.to)}</b><br>${pct(i.hwy_share)} highway, ${nf1.format(i.kmpl)} km/L<br>${nf.format(i.km)} km`;
      } },
      xAxis: axis({ type: "value", min: 0, max: 1, name: "share of distance on the highway", nameLocation: "middle", nameGap: 26, axisLabel: { ...FONT, formatter: (v) => pct(v) } }),
      yAxis: axis({ type: "value", name: "km/L", scale: true }),
      series: [
        { name: "Clean stretch", type: "scatter", data: ok.map((i) => [i.hwy_share, i.kmpl, i.km]),
          symbolSize: (d) => 6 + Math.sqrt(d[2]) / 3, itemStyle: { color: C.amber, borderColor: C.night, borderWidth: 2 } },
        { name: "Least-squares fit", type: "line", data: [[0, b0], [1, b0 + b1]], showSymbol: false, lineStyle: { color: C.beam, width: 2 } },
      ],
    });
    $("#n-hwy").textContent = `Each 10 points of highway share adds about ${nf2.format(b1 / 10)} km/L (r = ${nf2.format(r)}, ${ok.length} stretches). Dot size is the stretch's distance. The scatter is wide because a 37 L tank only "measures" fuel to within a few litres per stretch.`;

    const miss = F.missing;
    $("#t-missing").innerHTML = miss.length
      ? `<thead><tr><th>Stretch</th><th class="num">km</th><th class="num">Logged</th><th class="num">Needed</th><th class="num">Unlogged</th></tr></thead><tbody>` +
        miss.map((m) => `<tr class="flag"><td>${short(m.from)} to ${short(m.to)}</td><td class="num">${nf.format(m.km)}</td><td class="num">${nf1.format(m.logged_l)} L</td><td class="num">${nf1.format(m.needed_l)} L</td><td class="num">${nf1.format(m.unlogged_l)} L</td></tr>`).join("") + "</tbody>"
      : "<tbody><tr><td>No gaps found.</td></tr></tbody>";
    $("#n-missing").textContent = miss.length
      ? `Sized with the model below, about ${nf.format(t.unlogged_l)} L (roughly ${rupees(t.unlogged_l * t.avg_rate)}) went into the tank without making it into the log. These stretches are left out of the economy figures and the model.`
      : "";
    $("#m-econ").innerHTML = `<p>A brim fill (≥ ${k.brim_l} L) is assumed to leave the tank full, so the fuel burned between two brim fills is everything bought after the first, up to and including the second. Distance is the corrected odometer difference at the snapped fill moments. Top-ups in between are summed in. Residual tank-level uncertainty at each end is a few litres, which is why single stretches are noisy and the model below pools them.</p>
      <p>A stretch is flagged when its km/L exceeds the ARAI type-approval figure (${nf2.format(k.arai_kmpl)} km/L for the i20 1.2 petrol). City and highway kilometres come from trips (a trip averaging ≥ ${k.hwy_kmh} km/h while moving counts as highway), rescaled so they add up to the odometer distance.</p>`;
  }

  // ---------- Bayesian model ----------
  function model() {
    const m = F.model, c = m.coef, sd = m.sd;
    $("#h-model").textContent = `City driving burns ${nf1.format(c.city_l100)} L/100 km and the highway ${nf1.format(c.hwy_l100)}. Standing still costs ${nf2.format(c.idle_lph)} L every hour.`;
    $("#l-model").textContent = `That's ${nf1.format(m.kmpl_city)} km/L in town and ${nf1.format(m.kmpl_hwy)} km/L on the highway. City kilometres and idle hours rise together in traffic, so plain least squares can't tell them apart. Weak priors from engine physics keep the fit physical, and the data moves them.`;
    Object.keys(COEF).forEach((key, j) => {
      const cv = m.curves[key], meta = COEF[key];
      chart(`#c-post-${j}`, {
        title: { text: `${meta.label} (${meta.unit})`, left: 0, top: 0, textStyle: { color: C.ink, fontFamily: "Instrument Sans", fontSize: 14, fontWeight: 500 } },
        grid: { left: 12, right: 12, top: 56, bottom: 28 },
        legend: legend({ top: 26, left: 0, right: "auto", data: ["Prior", "Posterior"] }),
        tooltip: { ...TT, trigger: "axis", formatter: (ps) => `${nf2.format(cv.x[ps[0].dataIndex])} ${meta.unit}<br>` + ps.map((p) => `${p.seriesName}: ${nf2.format(p.value[1])}`).join("<br>") },
        xAxis: axis({ type: "value", min: cv.x[0], max: cv.x[cv.x.length - 1], splitLine: { show: false },
          axisLabel: { ...FONT, showMinLabel: false, showMaxLabel: false, hideOverlap: true } }),
        yAxis: axis({ type: "value", show: false }),
        series: [
          { name: "Prior", type: "line", data: cv.x.map((x, i) => [x, cv.prior[i]]), showSymbol: false, lineStyle: { color: C.fog, type: "dashed", width: 2 }, itemStyle: { color: C.fog } },
          { name: "Posterior", type: "line", data: cv.x.map((x, i) => [x, cv.posterior[i]]), showSymbol: false, lineStyle: { color: C.amber, width: 2 }, itemStyle: { color: C.amber },
            areaStyle: { color: "rgba(201,124,18,0.22)" },
            markLine: { silent: true, symbol: "none", lineStyle: { color: C.amber, type: "solid", width: 1 }, label: { color: C.ink, fontFamily: "Instrument Sans", formatter: nf2.format(c[key]) }, data: [{ xAxis: c[key] }] } },
        ],
      });
    });
    $("#t-coef").innerHTML = `<thead><tr><th>Coefficient</th><th class="num">Prior</th><th class="num">Posterior mean</th><th class="num">95% interval</th><th class="num">Implied km/L</th></tr></thead><tbody>` +
      Object.entries(COEF).map(([key, meta]) => {
        const lo = c[key] - 1.96 * sd[key], hi = c[key] + 1.96 * sd[key], p = m.prior[key];
        const kl = meta.kmpl ? `${nf1.format(meta.kmpl(c[key]))} <span class="muted">(${nf1.format(meta.kmpl(hi))}–${nf1.format(meta.kmpl(lo))})</span>` : "—";
        return `<tr><td>${meta.label}, ${meta.unit}</td><td class="num">${nf2.format(p.mean)} ± ${nf2.format(p.sd)}</td><td class="num">${nf2.format(c[key])}</td><td class="num">${nf2.format(lo)} to ${nf2.format(hi)}</td><td class="num">${kl}</td></tr>`;
      }).join("") + "</tbody>";

    const fit = m.fitted;
    const lim = Math.ceil(Math.max(...fit.flatMap((f) => [f.actual, f.pred])) / 10) * 10;
    chart("#c-fit", {
      grid: { left: 52, right: 16, top: 40, bottom: 44 },
      legend: legend({ data: ["Stretch", "Perfect prediction"] }),
      tooltip: { ...TT, trigger: "item", formatter: (p) => {
        if (p.seriesIndex === 1) return "Actual = predicted";
        const f = fit[p.dataIndex];
        return `<b>${long(f.from)} to ${long(f.to)}</b><br>Bought ${nf1.format(f.actual)} L, model says ${nf1.format(f.pred)} L`;
      } },
      xAxis: axis({ type: "value", min: 0, max: lim, name: "predicted litres", nameLocation: "middle", nameGap: 28 }),
      yAxis: axis({ type: "value", min: 0, max: lim, name: "litres bought" }),
      series: [
        { name: "Stretch", type: "scatter", symbolSize: 10, data: fit.map((f) => [+f.pred.toFixed(2), f.actual]), itemStyle: { color: C.amber, borderColor: C.night, borderWidth: 2 } },
        { name: "Perfect prediction", type: "line", data: [[0, 0], [lim, lim]], showSymbol: false, lineStyle: { color: C.fog, type: "dashed" } },
      ],
    });

    const ev = m.evidence;
    const top = Math.max(...ev.log_evidence);
    const best = ev.log_evidence.indexOf(top);
    const rel = ev.sigma.map((sg, i) => [sg, +(ev.log_evidence[i] - top).toFixed(3)]).filter((d) => d[1] >= -12);
    chart("#c-evidence", {
      grid: { left: 56, right: 16, top: 40, bottom: 44 },
      tooltip: { ...TT, trigger: "axis", formatter: (ps) => `σ = ${nf2.format(ps[0].value[0])} L<br>${nf2.format(ps[0].value[1])} log units below the best σ` },
      xAxis: axis({ type: "value", min: rel[0][0], max: rel[rel.length - 1][0], name: "noise scale σ (litres per stretch)", nameLocation: "middle", nameGap: 28, splitLine: { show: false } }),
      yAxis: axis({ type: "value", max: 0.5, name: "log evidence vs best" }),
      series: [{ type: "line", data: rel, showSymbol: false, lineStyle: { color: C.amber, width: 2 },
        markPoint: { symbol: "circle", symbolSize: 10, itemStyle: { color: C.sodium }, label: { show: true, position: "top", color: C.ink, fontFamily: "Instrument Sans", formatter: `σ = ${nf1.format(ev.sigma[best])} L` },
          data: [{ coord: [ev.sigma[best], 0] }] } }],
    });
    const gain = 1 - m.loo_mae / m.naive_loo_mae;
    $("#s-model").innerHTML =
      stat(nf1.format(m.loo_mae), "L", "Leave-one-out error", `Mean absolute error per stretch, ${pct(gain)} lower than a single km/L figure (${nf1.format(m.naive_loo_mae)} L)`) +
      stat(nf2.format(m.r2), "", "In-sample R²", `Across ${m.n_intervals} clean stretches`) +
      stat(nf1.format(m.sigma_l), "L", "Noise per stretch", "Chosen by maximum marginal likelihood") +
      stat(nf2.format(m.posterior_corr[0][1]), "", "City–highway posterior correlation", "Negative: the data trades one off against the other");
    const P = m.prior;
    $("#m-model").innerHTML = `<p>For each clean stretch <code>j</code>: <code>litres_j = a·city_km_j/100 + b·hwy_km_j/100 + c·idle_h_j + ε_j</code>, with <code>ε_j ~ N(0, σ²)</code>. Priors are independent Gaussians: <code>a ~ N(${P.city_l100.mean}, ${P.city_l100.sd}²)</code> L/100 km, <code>b ~ N(${P.hwy_l100.mean}, ${P.hwy_l100.sd}²)</code> L/100 km, <code>c ~ N(${P.idle_lph.mean}, ${P.idle_lph.sd}²)</code> L/h, typical values for a 1.2 L naturally aspirated petrol engine.</p>
      <p>The model is conjugate, so the posterior is Gaussian in closed form: <code>Σ_n = (Σ_0⁻¹ + XᵀX/σ²)⁻¹</code>, <code>μ_n = Σ_n(Σ_0⁻¹μ_0 + Xᵀy/σ²)</code>. σ is set by maximising the marginal likelihood <code>y ~ N(Xμ_0, XΣ_0Xᵀ + σ²I)</code> over a grid (empirical Bayes). Leave-one-out refits the posterior without each stretch and predicts it; the baseline divides each stretch's distance by the pooled km/L of the others. Intervals shown are ±1.96 posterior SD.</p>
      <p>Caveats: ${m.n_intervals} stretches is a small sample; the highway/city split is per trip, not per kilometre; and AC use, load and cold starts are folded into the coefficients rather than modelled.</p>`;
  }

  // ---------- costs ----------
  function costs() {
    const t = F.totals, mo = F.monthly.filter((r) => r.km > 0 || r.spend > 0);
    $("#h-costs").textContent = `Fuel costs you ₹${nf2.format(t.rs_per_km_model)} a kilometre. Idling alone has cost ${rupees(t.idle_cost)}.`;
    $("#l-costs").textContent = `Every trip gets an estimated fuel burn from the model (its distance at the city or highway rate, plus its idle time) priced at the rate of your most recent fill-up.`;
    $("#s-costs").innerHTML =
      stat(rupees(t.est_cost_total), "", "Estimated fuel burned", `${nf.format(t.est_l_total)} L across every recorded trip`) +
      stat(rupees(t.idle_cost), "", "Cost of idling", `${nf.format(t.idle_l)} L, ${pct(t.idle_share_of_fuel)} of your fuel`) +
      stat(rupees(t.premium_extra), "", "Extra paid for premium", `${t.premium_fills} fill${t.premium_fills === 1 ? "" : "s"} vs the regular price nearby`) +
      stat(nf.format(t.unlogged_l), "L", "Bought but not logged", `About ${rupees(t.unlogged_l * t.avg_rate)} across ${t.missing_fills} gaps`);

    chart("#c-monthly", {
      grid: { left: 64, right: 16, top: 40, bottom: 32 },
      legend: legend({ data: ["Paid at the pump", "Burned, per the model"] }),
      tooltip: { ...TT, trigger: "axis", axisPointer: { type: "shadow", shadowStyle: { color: "rgba(156,180,214,0.06)" } },
        formatter: (ps) => { const r = mo[ps[0].dataIndex];
          return `<b>${fmtDate(r.month + "-01", { month: "long", year: "numeric" })}</b><br>Paid ${rupees(r.spend)} for ${nf1.format(r.litres)} L<br>Burned ≈ ${rupees(r.est_cost)} (${nf1.format(r.est_l)} L over ${nf.format(r.km)} km)<br>Of which idling ${rupees(r.idle_cost)}`; } },
      xAxis: axis({ type: "category", data: mo.map((r) => monthName(r.month)), splitLine: { show: false } }),
      yAxis: axis({ type: "value", axisLabel: { ...FONT, formatter: (v) => rupees(v) } }),
      series: [
        { name: "Paid at the pump", type: "bar", barMaxWidth: 22, barGap: "15%", data: mo.map((r) => r.spend), itemStyle: { color: C.amber, borderRadius: [4, 4, 0, 0] } },
        { name: "Burned, per the model", type: "bar", barMaxWidth: 22, data: mo.map((r) => r.est_cost), itemStyle: { color: C.beam, borderRadius: [4, 4, 0, 0] } },
      ],
    });

    const city = [t.city_share_km, t.city_share_fuel];
    chart("#c-share", {
      grid: { left: 72, right: 16, top: 36, bottom: 24 },
      legend: legend({ data: ["City", "Highway"] }),
      tooltip: { ...TT, trigger: "item", formatter: (p) => `<b>${p.seriesName}</b>: ${pct(p.value)} of ${p.name.toLowerCase()}` },
      xAxis: axis({ type: "value", max: 1, axisLabel: { ...FONT, formatter: (v) => pct(v) } }),
      yAxis: axis({ type: "category", inverse: true, data: ["Distance", "Fuel"], splitLine: { show: false } }),
      series: [
        { name: "City", type: "bar", stack: "s", barWidth: 22, data: city, itemStyle: { color: C.amber },
          label: { show: true, color: C.night, fontFamily: "Instrument Sans", fontWeight: 600, formatter: (p) => pct(p.value) } },
        { name: "Highway", type: "bar", stack: "s", barWidth: 22, data: city.map((v) => 1 - v), itemStyle: { color: C.beam },
          label: { show: true, color: C.ink, fontFamily: "Instrument Sans", fontWeight: 600, formatter: (p) => pct(p.value) } },
      ],
    });
    const m = F.model.coef;
    $("#n-share").textContent = `A city kilometre costs ${nf1.format(m.city_l100 / m.hwy_l100)}× a highway one before idling is counted, so the ${pct(t.city_share_km)} of distance you drive in town takes ${pct(t.city_share_fuel)} of the fuel.`;

    const edges = [0, 10, 20, 40, 80, 160, 320, Infinity];
    const labels = ["under ₹10", "₹10–20", "₹20–40", "₹40–80", "₹80–160", "₹160–320", "₹320+"];
    const bins = labels.map(() => ({ n: 0, cost: 0 }));
    F.trips.forEach((tr) => { const i = edges.findIndex((e, j) => tr.cost >= e && tr.cost < edges[j + 1]); bins[i].n++; bins[i].cost += tr.cost; });
    const total = bins.reduce((a, b) => a + b.cost, 0), ntrips = F.trips.length;
    chart("#c-tripcost", {
      grid: { left: 44, right: 16, top: 16, bottom: 32 },
      tooltip: { ...TT, trigger: "item", formatter: (p) => { const b = bins[p.dataIndex];
        return `<b>${labels[p.dataIndex]}</b><br>${b.n} trips (${pct(b.n / ntrips)})<br>${rupees(b.cost)} together (${pct(b.cost / total)} of the total)`; } },
      xAxis: axis({ type: "category", data: labels, splitLine: { show: false }, axisLabel: { ...FONT, interval: 0, hideOverlap: true } }),
      yAxis: axis({ type: "value", name: "trips" }),
      series: [{ type: "bar", barMaxWidth: 40, data: bins.map((b) => b.n), itemStyle: { color: C.amber, borderRadius: [4, 4, 0, 0] } }],
    });
    const cheap = bins.slice(0, 3), cheapN = cheap.reduce((a, b) => a + b.n, 0), cheapC = cheap.reduce((a, b) => a + b.cost, 0);
    const dear = bins.slice(5), dearN = dear.reduce((a, b) => a + b.n, 0), dearC = dear.reduce((a, b) => a + b.cost, 0);
    $("#n-tripcost").textContent = `Trips under ₹40 are ${pct(cheapN / ntrips)} of your trips but ${pct(cheapC / total)} of the fuel bill. The ${dearN} trips over ₹160 account for ${pct(dearC / total)}. Bin widths double, so read the bars as counts per range.`;

    $("#m-costs").innerHTML = `<p>Per trip: <code>litres = rate × km/100 + c × idle_h</code>, where <code>rate</code> is the city or highway posterior mean and <code>km</code> is the corrected distance (reported + ${nf2.format(F.calibration.delta)} km). Price is the ₹/L of the latest fill on or before the trip (an as-of join). Monthly "paid" is what you spent at the pump that month, so it leads or lags "burned" depending on when you filled; over the whole period they should agree once the unlogged fuel is added back.</p>
      <p>Premium extra = Σ litres × (premium rate − median regular rate within 45 days). Premium is any fill more than ${pct(F.constants.premium_markup - 1)} above your median price, which keeps Rajasthan's higher regular prices from being mistaken for premium.</p>`;
  }

  // ---------- fuel level ----------
  function level() {
    const fl = F.fuel_level;
    const distinct = new Set(fl.map((r) => r[1] + "/" + r[2])).size;
    $("#h-level").textContent = `The fuel gauge history starts now: ${fl.length} reading${fl.length === 1 ? "" : "s"} so far.`;
    $("#l-level").textContent = fl.length
      ? `Each sync records the tank level and range. The latest says ${fl[fl.length - 1][1]}% with ${nf.format(fl[fl.length - 1][2])} km of range (${distinct} distinct value${distinct === 1 ? "" : "s"} so far). Once a few refuels are captured between syncs, the jumps in level give a second, log-independent estimate of fill sizes and km/L to check this page against.`
      : "Each sync records the tank level and range; nothing captured yet.";
    $("#foot").textContent = `Fuel log: ${F.source}. Built from your Bluelink data and fuel log, stored only on this Mac.`;
  }

  async function main() {
    try { F = await LB.load("fuel.json"); }
    catch { LB.fail("No fuel log found. Put your fuel CSV in the project folder and run <code>uv run insights.py</code>."); return; }
    LB.run([head, calibration, fills, economy, model, costs, level]);
    LB.initSync();
  }
  main();
})();
