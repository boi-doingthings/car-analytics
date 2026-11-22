# Baseline validation and publication

## Publication scope

This repository starts from a sanitized source snapshot with fresh Git history. The older private local history is intentionally not imported. Author and committer metadata for the baseline use a generic project identity.

Excluded: actual raw and derived vehicle records, private fuel/service source files, invoice images, historical planning documents with personal context, signing-team identifiers, provider authorization material, environment files, build caches and user-specific paths. The app icon was visually inspected. Committed archive fixtures and test inputs are invented; inherited station labels and fixture identifiers were generalized.

The public provider client loads authorization configuration from a local ignored plist or process environment. Its unit tests inject an invented configuration. The existing private app and archive remain separate. This snapshot is a code baseline; it does not provide working vehicle-provider access without private local setup.

## Executed checks

| Check | Result |
|---|---|
| Original private-checkout JavaScript tests | 48 passed, including available private oracle comparisons |
| Public-checkout JavaScript tests | 31 passed, 21 explicit private-data skips, zero failures |
| Public Swift core tests | 56 passed across XCTest and Swift Testing; one opt-in real-login smoke test skipped |
| Public desktop and synthetic migration tests | 8 passed |
| Browser phone-layout review | Four pages checked at 390 × 844; zero JavaScript page errors; Fuel horizontal overflow confirmed |
| Known private-value audit | No matches in publication candidates for local environment values, known personal identifiers, private station names or removed provider constants |
| Publication policy scan | No flagged tracked files |
| Gitleaks 8.30.1 credential scan | No leaks found; official binary checksum verified before execution |

The public JavaScript additions exercise synthetic full-pipeline analytics, missing refuels, schema warnings, conflict-copy exclusion and bare-context bundled/source agreement. Existing CLI tests also use synthetic archives. Migration tests check idempotence, source preservation, dry runs, conflict preflight and symlink escape refusal.

The production UI, provider network access and on-device signing were not revalidated as part of this planning baseline. Browser checks blocked third-party fonts and tiles. No private screenshots, test logs or environment contents are published. Repository CI is configured for analytics, desktop and Swift core checks; local test results do not imply a hosted CI run has completed.

## Development location

Continue development in this independently versioned checkout or a fresh clone of the public repository. Do not push branches or tags from the older private checkout. Ignore rules cannot sanitize historical commits.

Use branches and pull requests for v2 work. Keep a known-good baseline tag before implementation. Review generated outputs, fixtures, commit metadata and staged filenames before every push. The publication heuristic complements dedicated credential scanning and manual review; it cannot establish anonymity for arbitrary future content.
