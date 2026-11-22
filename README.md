# Car Analytics

An iPhone vehicle logbook and analytics application with a read-only desktop dashboard. It archives read-only Hyundai Bluelink India responses, records refuels/services/expenses, and computes trip, fuel, commute and maintenance insights locally.

This is a sanitized baseline of the existing application, with a proposal for the next generation. No personal archive, real invoices, account credentials, provider authorization constants or historical private Git commits are included. Historical analysis tests that require private inputs are explicitly skipped when those inputs are absent.

- [Current version review](docs/CURRENT_VERSION_REVIEW.md)
- [Detailed v2 product and engineering plan](docs/NEXT_VERSION_PLAN.md)
- [Validation and publication notes](docs/BASELINE_VALIDATION.md)
- [Data dictionary](DATA_DICTIONARY.md)
- [Log record schemas](docs/entry-schemas.md)

## Public development and tests

Requires Node.js 22 or newer. Install the analytics build tool and run the public test suite:

```sh
cd analytics
npm ci
npm test
npm run build
```

The suite includes synthetic CLI and end-to-end analytical tests. Optional private-archive regressions report skips in a fresh checkout. They are not a substitute for public synthetic coverage.

The core Swift package can be tested separately on a Mac with a compatible Xcode toolchain:

```sh
swift test --package-path ios/I20Core
```

Generate the iOS project with XcodeGen (`cd ios` then `xcodegen generate`), open it in Xcode and select your own development team locally. The app targets iOS 18 or later. Account/device-dependent signing and distribution are configured locally.

## Private configuration

The public app deliberately contains no working provider authorization material. Copy `ios/App/Resources/Bluelink.example.plist` to `Bluelink.local.plist` in the same folder and supply the authorized provider configuration locally. The local plist is ignored by Git and read from the app bundle. It is embedded in a locally built app, so treat build artifacts as private. The configuration keys can alternatively be supplied as process environment variables for a CLI/smoke test.

Personal Bluelink login credentials are entered through the app and stored in the device Keychain. Never put them in a plist, source, archive, issue or commit. The Python reference tooling can read a local `.env` based on `.env.example`; it is not required for public tests.

The public synthetic Swift protocol tests inject invented configuration and never contact a real vehicle. A real-login smoke test remains opt-in and requires local configuration and credentials.

## Archive and desktop viewer

The iPhone writes into a user-selected folder named `i20_book`. It contains raw provider responses and versioned log files, with derived outputs kept separately. Never store the actual archive inside this repository.

The desktop dashboard requires Python 3.12+ and Node.js; its server uses only the Python standard library. Point `I20_BOOK` to your selected private archive folder and start:

```sh
python3 serve.py --no-open
```

It binds to localhost on port 8420 by default. `I20_NODE` can select the Node executable. The viewer reads the archive without changing it. Derived dashboard JSON is ignored by Git. For offline analysis without launching the viewer:

```sh
node analytics/cli.mjs --book "$I20_BOOK" --out ./data/derived
```

The analytics modules are shared between Node and iOS JavaScriptCore. ECharts and Leaflet are vendored; map tiles and legacy web fonts still require network access. The frozen Python scripts remain a reference implementation and require the dependencies in `pyproject.toml`.

## Repository structure

| Directory | Purpose |
|---|---|
| `ios/App` | SwiftUI application, native logging, Keychain, sync and WebKit dashboard |
| `ios/I20Core` | Archive, collector, provider client and entry logic |
| `analytics` | Shared JavaScript analytics, CLI, bundler and tests |
| `web` | Existing Overview, Map, Performance and Fuel dashboards |
| `tests`, `tools` | Desktop tests and migration/reference utilities |
| `docs` | Architecture review, record schemas and next-version plan |

## Data and contribution hygiene

Run `python3 tools/check_publication.py` before committing. CI also scans for common personal-path, private-input and credential patterns. This complements manual review and a dedicated secret scanner; it does not prove anonymity. Never commit actual routes, vehicle identifiers, receipts, login material, signing files, local machine paths or personal commit metadata. Test fixtures are invented and documented as synthetic.

No application license is granted by this baseline. Preserve upstream notices for vendored dependencies; review licensing and notices before broader redistribution.
