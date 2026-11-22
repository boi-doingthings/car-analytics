# V2 native foundation

Development branch: `codex/v2-native-foundation`. This first implementation establishes native daily workflows and consistent analytical snapshots. The broader roadmap remains in [the v2 plan](NEXT_VERSION_PLAN.md).

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

This increment does not refit the legacy fuel model or claim improved causal inference. Internal leave-one-out errors still use the legacy tuning procedure and are labelled accordingly. City/highway remains a whole-trip speed proxy. Unverified maintenance history remains explicitly unconfirmed.

## Validation

Unit regressions cover decoding, current India-calendar windows, missing metrics, source freshness, supported and unsupported comparison cohorts, scenario units/invalid inputs, complete-generation publication, failed publication, cancellation, queued edits and archive changes. Native UI checks use a temporary copy of the invented fixture archive and exercise navigation and refuelling without real credentials or iCloud.

CI retains analytics, desktop, core Swift and secret-scanning checks and adds a generated iPhone-app build plus simulator tests. Personal screenshots, logs, derived outputs, signing material and provider configuration remain excluded from Git.

## Remaining roadmap

Home/Lock Screen widgets and App Group provisioning, incremental database indexing, full conflict-resolution workflows, fuel interval editing, a corrected nested/chronological model evaluation, experiments notebook, restore/export tools and physical-device release acceptance remain future increments. No paid account, provider network calls or physical-device deployment are required for the synthetic development checks.

### First increment test results

The complete local simulator run passed 98 app unit tests and three UI tests, including the new archive-switch regressions and the existing refuel happy path. Shared JavaScript checks passed 31 public tests with 21 explicitly skipped private-history regressions. Desktop/migration checks passed eight tests. The publication policy scan and Gitleaks scan reported no findings. Physical-device acceptance and production-provider access remain untested in this increment.
