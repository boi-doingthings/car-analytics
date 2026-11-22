# Current version technical review

This review covers the Swift/iPhone app, shared JavaScript analytics, web dashboard, desktop viewer, archive/storage rules, tests and publication surface. It is a source-level review with executable checks where documented; it is not a completed real-device usability study.

## Overall assessment

The project has outgrown its presentation architecture. Its analytics and raw-data preservation are considerably more advanced than its phone interaction model. Reuse the collector, archive and analytical core; build a native daily interface and improve measurement discipline around the estimates.

| Area | Assessment | Priority |
|---|---|---|
| Data ownership | Verbatim provider records, portable versioned logs and rebuildable outputs are strong choices | Preserve |
| Collection safety | Read-only client, finality rules, atomic writes, retries, placeholder/symlink protections | Preserve and extend failure testing |
| Analytical breadth | Fuel calibration, Bayesian consumption, clustering, forecasts and reliability already exist | Improve validation and labels |
| Mobile navigation | Native tabs contain a separate four-page web navigation | Replace with one native hierarchy |
| Mobile layout | Large hero/sections, wide calendar, dense charts and report-length screens | Redesign around compact tasks |
| Freshness | Twelve-hour trigger, separate collection and analytics failure cases | Separate observation, collection and generation ages |
| Rebuild scheduling | An edit-triggered rebuild can be dropped while sync is running | Queue invalidation |
| Output consistency | Derived artifacts replaced individually | Atomic generation manifest |
| Cloud conflicts | Noncanonical conflict-copy filenames ignored by analytics | Add explicit review and resolution |
| Performance | Whole-archive scans, full JavaScript input, many placeholder tasks | Profile, isolate and index incrementally |
| Models | Useful but several heuristic/proxy assumptions can read too confidently | Validate, qualify and suppress unsupported results |
| Public reproducibility | Several tests depend on private histories and golden outputs | Synthetic public equivalents plus explicit optional private tests |

## Source references and implications

- `ios/App/I20LogbookApp.swift`: Dashboard, Log and Settings root tabs; setup requires both archive access and credentials. A cached-data/demo mode can make onboarding more useful before login is ready.
- `ios/App/Dashboard/DashboardView.swift`: WebKit navigation, reload after successful runs and native pull-to-refresh. Existing polish is reusable during migration.
- `web/styles.css`: responsive grids exist, but a large hero, wide calendar and large fixed-height charts preserve a desktop report structure.
- `ios/App/Sync/SyncCoordinator.swift`: stale-after threshold, full sync versus analytical rebuild, run-in-progress guards and scoped errors. Add queued rebuilds and separate publication state.
- `ios/App/Sync/AnalyticsRunner.swift`: placeholder downloads, JSON transfer into JavaScriptCore, old-output retention for incomplete cloud downloads and per-output publication. Introduce explicit work isolation, limits and generations.
- `ios/I20Core/Sources/I20Core/Book.swift`: archive boundary checks and atomic file operations. Keep these constraints for future imports and exports.
- `ios/I20Core/Sources/I20Core/Collector.swift`: preservation of final days and retained routes, source-time semantics and resumable collection. Add user-visible archival coverage and risk.
- `analytics/src/index.js`: page-level failure isolation, version checks and a dependency on overview enrichment before performance. Replace implicit mutation with a normalized contract.
- `analytics/src/fuel.js`: useful prior/posterior structure and explicit missing intervals; constant calibration, threshold classifications, model selection leakage and incomplete predictive uncertainty warrant review.
- `analytics/src/performance.js`: deterministic clustering and descriptive statistics; long-soak and interpolated dynamics need proxy labels, and daily-distance forecasts need stronger backtests.
- `analytics/src/insights.js`: maintenance reset and ownership-cost integration; use aligned windows and distinguish inferred maintenance history from confirmed service work.
- `web/common.js` and HTML pages: external tile/font dependencies remain despite vendored chart/map libraries.

The detailed product architecture, model changes, feature specifications, migration strategy and acceptance gates are in [the v2 plan](NEXT_VERSION_PLAN.md).

## Phone viewport check

A Chromium rendering check used a 390 × 844 pixel viewport with map tiles and remote fonts blocked. Overview measured 12,407 pixels tall, Performance 13,752 and Fuel 10,396. Fuel’s document width was 431 pixels against the 390-pixel viewport. Map fitted within the viewport. All four pages reported no JavaScript page errors in that check. These are browser layout observations, not a native-device acceptance test. Personal screenshots and metric values are excluded from this repository.
