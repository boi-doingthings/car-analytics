# Native analytics migration

The native app should expose the existing analytical depth within its own navigation. The desktop dashboard remains a desktop viewer; the phone should not require Lab → Detailed analysis → another navigation bar.

## Information architecture

| Destination | Native content |
|---|---|
| Today | Recent briefing and shortcuts, without repeating the full analytical archive |
| Trips | Odometer and lifetime coverage, daily activity calendar, monthly kilometres, searchable drives, one rich journey debrief with map/replay, speed, acceleration context, events and comparison |
| Atlas | Independent historical route map, date-range exploration, route density and chronological playback with pause/scrub controls |
| Garage | Vehicle/service context, complete maintenance schedule and reminders, full service timeline, invoices, parts/labour, expenses and recorded running costs |
| Lab | Driving rhythm, weekday/hour patterns, idle hotspots, journey distributions and all performance studies, grouped into focused native chart cards |
| Lab → Fuel & scenarios | Historical refuels, prices/brands, observed intervals, calibration, model evidence, costs and tank reconstruction alongside the existing hypothetical calculator |

Atlas is a fifth top-level tab. Trips remains the single destination for an individual journey; analytical outliers and chart selections can lead there. Fuel history and the scenario calculator form one tool rather than separate duplicated dashboards. Service records remain owned by Garage.

## Coverage checklist

The implementation audit follows the actual desktop sections and their published JSON fields:

- Overview: odometer/coverage, daily calendar, monthly distance, weekday/hour rhythm, weekday averages, directional commute, idle hotspots/hour, trip explorer, provider events, top-speed distribution, trip-length distribution, service plan/history, running costs and fuel-level context.
- Map: full historical routes, geographic density, date controls and chronological time lapse.
- Performance: speed bands, relative positive acceleration, trip archetypes and silhouette support, duration/distance scaling and outliers, directional commute distributions/departure slots/weekdays, parked-time/cold-start proxy, correlations, weekly-distance forecast and monthly trends.
- Fuel: odometer calibration, fill quantities and paid prices, brands, observed economy intervals/highway share/log gaps, coefficient priors/posteriors and validation, fitted interval fuel/noise evidence, monthly paid-versus-modelled consumption, city/highway fuel mix, per-trip estimates and tank reconstruction.

Each chart needs a useful empty/unsupported state. Native replacements must retain explanatory limitations instead of converting model outputs into vehicle telemetry. Any remaining parity limits must be listed at delivery.

## Delivery order

1. Extend the shared, typed analytical snapshot and test decoding against synthetic generated outputs, including missing and legacy fields.
2. Build native Trips/Atlas, Lab/performance/fuel, and Garage in parallel with separate file ownership.
3. Integrate the five-tab workspace and remove the embedded-dashboard entry from normal phone navigation once its native destinations are present.
4. Verify analytical units, calendar boundaries, route breaks, bounded chart data and playback cancellation; validate all key navigation and read-only behavior in the simulator.
5. Inspect phone-size screenshots in light/dark appearances, publish only sanitized source on the development branch, and document physical-device acceptance checks.

## Design and correctness constraints

- Use SwiftUI Charts and MapKit; no full-page embedded desktop replacement.
- Render a small number of focused cards at a time, with readable labels, selection, filtering and drilldowns. Long histories need bounded plot samples without changing summary denominators.
- Calendar gaps are unknown unless archive coverage establishes otherwise. Displayed averages must disclose their denominator.
- Provider-reported speed/events remain distinct from GPS estimates; acceleration from coarse archived samples cannot stand in for high-frequency telemetry.
- Preserve route discontinuities, missing measurements, model uncertainty and descriptive-versus-causal distinctions.
- Playback runs only after an explicit action and stops when hidden/backgrounded. No idle polling, analytical rebuilds or permanent animation loop is introduced by a chart.
- All new views read the existing analytical generation or log readers. This migration does not change collector retention or archive write consent.
- Use invented test archives. Keep provider configuration, real routes, screenshots of personal history, local paths, credentials and signing material outside Git.

## Implemented native destinations

Normal app navigation now uses Today, Trips, Atlas, Garage and Lab. The Detailed analysis link is removed. The desktop viewer and shared JavaScript analytical engine remain available; native screens consume the same published outputs instead of maintaining a second fuel/performance fitting engine.

Trips exposes odometer/archive context and a separate Driving activity tool with selectable monthly bars and day-intensity calendar. One debrief owns recorded summary metrics, route playback, GPS-derived speed/acceleration, event breakdown, fuel attribution and historical comparisons. Atlas layers routes, speed, departure time, geographic visit density, inferred places, historical slow areas and the last reported parking location. Its date range, cursor, step controls and time lapse lead back to that same debrief.

Lab directly switches between Patterns and Performance. Fuel & scenarios combines the existing calculator with historical exploration, calibration, interval review, coefficient distributions, model support and held-out validation, costs, fuel mix and tank/gauge reconstructions. Garage directly exposes full service/invoice history, attachment images, the complete maintenance plan, reminders and running-cost context. Record browsing does not require write consent.

Review fixes include generation-ID cache invalidation, missing fuel rates staying unknown, archive-pinned invoice loading, full-row journey touch targets, grouped comparison bars, one shared line/point legend, adaptive precision for small nonzero measurements, India-calendar plot axes and a workspace banner that reserves layout space instead of covering pushed navigation controls.

## Deliberate display and analytical limits

- Atlas preserves full selected-trip counts and density evidence, but limits the displayed route/speed overlays on large histories. Its map-details sheet discloses sampling; narrow the date range to inspect a smaller subset. Per-trip replay retains actual valid samples and does not invent positions through gaps.
- Monthly bars show up to 24 recorded months per page. The month picker retains access to the full calendar window, including months without archived trips. Missing dates are not certified zero-driving days.
- Plot-point sampling bounds drawing work. Exact-value controls inspect displayed values; summaries use their stated full cohort. Saved fitted models/reference diagrams retain their training window when exploratory trip filters change, with that scope disclosed.
- GPS acceleration remains a low-pass reconstruction from coarse provider breadcrumbs. Correlation, clusters, commute differences and model projections do not establish causes or high-frequency vehicle capability.
- These are native in-app chart cards and tools. Home/Lock Screen system widgets, an incremental database, full model-pipeline backtesting and production-provider acceptance remain separate roadmap items.
