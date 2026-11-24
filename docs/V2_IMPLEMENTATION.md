# V2 native foundation

Development branch: `codex/v2-native-foundation`. The current native analytics migration is described in [its coverage plan](NATIVE_ANALYTICS_MIGRATION.md); the broader roadmap remains in [the v2 plan](NEXT_VERSION_PLAN.md). Earlier increment notes below record how the foundation evolved.

## Available in this increment

- Today: a compact native briefing, actual 7/30/90-day windows, daily distance chart, latest journey, timestamped vehicle-reported fuel and a native refuel shortcut.
- Trips: searchable journey history, route/distance filters, native debrief, MapKit route geometry and historical journey comparisons. Comparisons require ten earlier matched trips across three dates, use median/IQR and disclose unobserved traffic/weather.
- Garage: direct refuel, service and expense entry; cash payments over an explicit 30-day window; observed full-to-full economy; maintenance schedule context; access to the existing editable logbook.
- Lab: a fuel scenario calculator with visible hypothetical inputs; data quality, collection/observation/publication freshness and model-support diagnostics; access to the existing detailed dashboard.
- An archive can be read and analysed without login credentials. Online collection still requires locally supplied provider configuration and credentials in Keychain.

The daily interface uses one native tab hierarchy. Existing forms continue to write to the selected archive; existing detailed web charts remain accessible from Lab.

## Reliability changes

Edits arriving during a sync coalesce into a follow-up analytical rebuild within the same awaited task. Analysis runs on an isolated worker, with bounded cloud-download concurrency. A complete generation publishes through one atomic manifest switch. Errors or cancellation preserve the last complete generation.

A local hash binds a generation to its selected archive without storing a personal folder path in analytical artifacts. Switching folders invalidates the previous archive’s read models. Vehicle observation time is distinct from collection time and analytical publication time. The web dashboard pins each page to one generation.

## Analytical boundaries

Recorded distance and calibrated distance remain separate. Missing amounts and incomplete trip metrics stay unknown instead of silently becoming zero. Modelled trip costs and scenario outputs are explicitly labelled estimates. Route rendering breaks at invalid points, time gaps and implausible jumps.

The consumption fit now retunes its noise parameter inside each leave-one-out fold and includes chronological expanding-window checks against a pooled-fuel-rate baseline. These diagnostics are conditional on the current reconstructed intervals: upstream odometer calibration and fill reconstruction are not independently backtested. City/highway remains a whole-trip speed proxy. Unverified maintenance history remains explicitly unconfirmed. No causal improvement is claimed.

## Validation

Unit regressions cover decoding, current India-calendar windows, missing metrics, source freshness, supported and unsupported comparison cohorts, scenario units/invalid inputs, complete-generation publication, failed publication, cancellation, queued edits and archive changes. Native UI checks use a temporary copy of the invented fixture archive and exercise navigation and refuelling without real credentials or iCloud.

CI retains analytics, desktop, core Swift and secret-scanning checks and adds a generated iPhone-app build plus simulator tests. Personal screenshots, logs, derived outputs, signing material and provider configuration remain excluded from Git.

## Remaining roadmap

Home/Lock Screen widgets and App Group provisioning, incremental database indexing, full conflict-resolution workflows, fuel interval editing, a corrected nested/chronological model evaluation, experiments notebook, restore/export tools and physical-device release acceptance remain future increments. No paid account, provider network calls or physical-device deployment are required for the synthetic development checks.

### First increment test results

The complete local simulator run passed 98 app unit tests and three UI tests, including the new archive-switch regressions and the existing refuel happy path. Shared JavaScript checks passed 31 public tests with 21 explicitly skipped private-history regressions. Desktop/migration checks passed eight tests. The publication policy scan and Gitleaks scan reported no findings. Physical-device acceptance and production-provider access remain untested in this increment.

## Real archive and analytical trust increment

Normal archive selection/restoration now defaults to read-only, with per-archive local write consent and separate opt-in automatic collection. The core writer rejects unauthorized writes/deletes, including held references after revocation. Canonical filenames and embedded IDs must match in native log loading and JavaScript analytics. Read-only logs have a static detail view rather than opening an edit form.

A standard-library backup tool creates and verifies an independent checksum-backed copy, preserves mtimes needed by legacy finality rules, and restores only to a new folder outside Git. See [the real archive rollout](REAL_ARCHIVE_ROLLOUT.md) before choosing the main archive.

Fuel diagnostics now report nested leave-one-out and chronological model/baseline MAE, signed bias and the number of held-out intervals. Insufficient history stays unavailable; future and overlapping intervals do not train an earlier prediction. The noise evidence calculation uses an equivalent small-matrix formulation so nested checks remain practical on-device. The legacy type-approval interval filter is unchanged and remains a separate modelling limitation.

### Safety and validation checks

The safety/validation increment passed 106 app unit tests and all four simulator UI tests, including explicit write consent, revocation, disabled automatic collection and byte-identical read-only archive rebuilding. Core storage/provider checks passed 60 tests with the opt-in live-login test skipped. JavaScript checks passed 44 public tests with 21 private-history skips. Backup/restore, migration and desktop checks passed 19 tests. A synthetic browser check also confirmed that unavailable validation errors render as unavailable instead of zero, with no page exceptions. No main archive or live vehicle account was used for these tests.

## Read-only refresh loop correction

The embedded detailed dashboard previously treated an old or absent collection timestamp as a reason to start another run on every page load. A read-only rebuild correctly leaves that timestamp unchanged, so the resulting page reload could start an endless rebuild cycle. Native lifecycle events also requested full rebuilds even when the archive was unchanged.

Automatic refresh now belongs to the native coordinator. Passive visits check a cached input signature, the India calendar day, the analytical script and the expected output files before running analysis. Saved edits and explicit refreshes still force analysis. A completed metadata check neither publishes a new generation nor reloads the detailed page. Foreground events arriving during an active run do not queue another rebuild. A materialized cloud file takes precedence over a lingering placeholder marker.

The first launch after this update rebuilds once to establish the new cache stamp. Thereafter, an unchanged archive should settle. The detailed page separates analytical publication from collection time and labels its read-only action “Rebuild”. Archive changes during analysis preserve the last complete generation and surface a retryable error instead of certifying stale results.

Removing incidental rebuilds also exposed a first-presentation form bug: the sheet action and archive root could come from different SwiftUI state updates. Logbook sheets and deletion confirmations now capture their selection and archive together, retaining archive-switch and write-consent guards.

Device acceptance: keep archive changes disabled, wait for the first analysis to finish, visit Today and Lab → Detailed analysis repeatedly, then background and reopen the app. No repeated recalculation should occur with unchanged inputs on the same day. An explicit refresh should complete once. A new day, changed analytical input, changed analytical script or missing output legitimately requires analysis. These checks avoid repeated full analysis; battery consumption has not been measured on a physical device.

Validation: 120 app unit tests and all four simulator UI tests passed. Tests include the actual embedded WebKit page remaining idle until explicit refresh, one reload per publication, metadata-cache reuse/invalidation, concurrent source changes and iCloud shadow placeholders. JavaScript checks passed 59 public tests with 21 private-history skips, including 15 sync-controller regressions. Publication and Gitleaks scans passed. All automated runs used synthetic archives.

## Native analytics migration (current)

The phone now has Today, Trips, Atlas, Garage and Lab tabs. Normal navigation no longer opens the desktop Detailed analysis page. Trips owns odometer/archive context, monthly/day activity and one shared journey debrief with route replay, speed/acceleration context, provider events and comparisons. Atlas provides independent historical map layers, date ranges, density, manual scrubbing and time lapse. Garage owns complete service/invoice browsing, image attachments, maintenance schedules, reminders and running costs. Lab directly exposes Patterns and Performance; Fuel & scenarios combines historical fuel exploration, calibration, diagnostics, tank/gauge paths and the calculator.

The [migration coverage document](NATIVE_ANALYTICS_MIGRATION.md) maps all former sections and lists intentional display limits. The analytical fitting engine remains shared with the desktop viewer. Snapshot decoding now exposes its full outputs, validates/caches route geometry once, precomputes history buckets and identifies published generations precisely. Large maps and plots bound rendering work, and playback stops when hidden/backgrounded.

Review also corrected missing fuel-model rates being presented as zero, archive identity on invoice loading, overlapping archive-banner/navigation controls, full-row activity touch regions, stacked comparison shares, duplicate series legends and insufficient precision for small values. These changes preserve the existing archive write-consent and collector-retention policies.

Validation passed 134 app unit tests and all eight native UI workflows, with focused reruns after interface fixes. Public JavaScript checks passed 59 tests with 21 private-history skips. A separate invented six-month archive exercised populated charts with 286 trips, 26 refuels, three trip clusters and 22 chronological fuel predictions; the native decoding/runner integration preserved archive bytes. Privacy and secret scans passed. No main archive or live provider calls were used in this work. Physical-device acceptance and battery profiling remain outstanding.

## Native color and chart readability

The native palette now uses adaptive blue actions, teal, indigo, violet, coral, amber and green on neutral system surfaces. Cards have tinted icon tiles and metrics retain readable semantic colors in both appearances. Atlas layer colors and signed analytical scales keep their original meaning.

Weekday comparisons use full labels, thick proportional bars and always-visible exact values. Selecting a row exposes its supporting trip/calendar counts. The hourly idle profile retains all 24 departure hours with sparse time labels, tap/drag selection, an hour menu and an accessible values disclosure. Missing engine-time observations remain unavailable rather than becoming zero. Long categorical charts scroll instead of compressing labels.

Provider event exposure defaults to braking, acceleration and overspeed comparisons, with a segmented weekday alternative. Counts and raw kilometres come from the same complete trip cohort; zero-distance exposure has no rate. The displayed evidence includes comparable trips and recorded distance. Four additional unit checks cover cohort alignment, unknown versus zero, invalid inputs and India-time weekday boundaries.

The Patterns section has an explicit accessibility container and bounded eager card layout, preserving each chart’s controls when scrolling. The hourly plot draws its sparse time labels separately from the chart’s automatic axis to prevent overlapping labels on phone widths. Touch inspection uses the plot coordinates without starting analysis or provider collection.

Validation: 138 app unit tests and all nine native UI workflows passed across consolidated/focused runs. Populated-history visual checks additionally exercised the comparison rows, hourly inspection and grouping switch in light/dark appearances using invented data. Privacy and secret scans passed. No main archive or live provider calls were used.

## Atlas space and rendering refinement

Atlas now uses a taller adaptive map (at least 340 points in portrait), with an expanded portrait map that hides the tab bar and retains playback controls. Expansion/collapse retains the last user camera. Landscape and accessibility text retain a scrolling layout. Speed, departure and density use colored legend swatches; optional reference layers explicitly describe their archive-wide/latest-reading scope.

Retained route and speed overlays prepare immutable MapKit geometry off the main thread after sampling, reusing it during scrubbing and playback. Existing overlay/point budgets and original disconnected route sections are preserved. Playback advances only whole drives, at most 50 updates, with an inspectable cadence for small histories. Date edits are staged until filter dismissal, preventing repeated projection work while choosing dates. Crossing either date endpoint updates both endpoints together, preventing a stale end date from reappearing. Archive data and provider collection are unchanged.

Validation: nine focused app unit tests passed for geometry reuse/coordinate fidelity, rendering budgets, date boundaries and whole-drive playback. Atlas UI checks passed with both the small fixture and an invented 286-trip history, covering expansion, all map layers, scrubbing, pause on tab changes, reference layers and drive navigation. A separate landscape check passed. Synthetic screenshots were reviewed; publication and secret scans passed. No main archive or live provider calls were used. Physical-device frame rates and battery usage were not measured.
