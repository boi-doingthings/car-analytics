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
