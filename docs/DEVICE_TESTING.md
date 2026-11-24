# Test the native v2 app

The development branch is `codex/v2-native-foundation`. The stable baseline remains on `main`; the native changes are reviewed through the draft pull request.

## Open in Xcode

Use the root of the **sanitized `car-analytics` checkout**, which is a separate Git repository from the original private project.

If your terminal is currently in the original `bluelink` directory, enter the nested checkout first:

```sh
cd public/car-analytics
git status --short --branch
```

Entering `public` alone is insufficient: it is still inside the original repository. The branch should be `codex/v2-native-foundation` once inside `public/car-analytics`. If you cloned `car-analytics` separately, enter that clone instead.

Then run:

```sh
git fetch origin
git switch codex/v2-native-foundation
git pull --ff-only origin codex/v2-native-foundation
npm ci --prefix analytics
npm run build --prefix analytics
cd ios
xcodegen generate
open I20Logbook.xcodeproj
```

Use the `I20Logbook` scheme. For a simulator, select an available iPhone and Run. For a physical phone, connect/pair it in Xcode, select it as the destination, choose your own team under Signing & Capabilities, and enable Developer Mode if the phone requests it. The app requires iOS 18 or later. Keep signing settings local; do not commit team identifiers, generated project files, credentials or provider configuration.

For main-history use, follow [the real archive rollout](REAL_ARCHIVE_ROLLOUT.md). Archive writes now require per-archive consent; an update without existing consent opens in read-only mode.

## First physical-device check with synthetic data

Copy the repository’s `ios/Tests/Fixtures/book` folder into a new test location in iCloud Drive using Finder. Rename only the copy to `i20_book`. Pick that copied folder in the app. These invented records include historical dates, so an empty recent 7-day briefing is expected; the historical journeys remain available under Trips.

This build uses the existing application bundle identifier, so installing it updates the installed app rather than adding a second app. It can retain the previous archive bookmark and Keychain login.

For this initial visual/offline check, download the copied folder before going offline. The current build starts picked/restored archives read-only unless you have already authorized that archive. Leave automatic collection off during this check. If an existing archive is restored, use Settings → Logbook folder → Re-pick folder to choose the test copy before adding or changing records. No Bluelink credentials are needed to rebuild and browse an existing archive. Read-only mode also prevents an existing Keychain login from beginning online collection into the test copy. Enable Allow archive changes only on the test copy when testing saves. The authoritative original archive stays outside the app and should remain unchanged by these test edits.

Check the following:

1. Today fits comfortably, larger text remains readable, and switching between 7/30/90 days is clear. Old vehicle readings must be labelled historical.
2. Trips shows the odometer and archive overview. Open Driving activity, choose a month, select a calendar day and open a journey. Search/filter the trip list, inspect provider speed/events and scrub the GPS-derived speed/acceleration replay. Invalid gaps must stay disconnected. Map geometry should remain viewable when tiles are unavailable.
3. Atlas is its own tab. Try routes, speed, departure-time and density layers; adjust the date range, fit the map, play/pause and scrub the time lapse. Switch tabs or background the app while playing: it must stop. Check the sampling disclosure on larger histories. Reduce Motion keeps manual scrubbing available.
4. Garage has direct service history, maintenance plan, reminders and read-only invoice details/attachments. Browse these with changes disabled. Enable changes only on the copied archive to add/edit/delete a clearly named test refuel. Verify that only the copy changed.
5. Lab exposes native Patterns and Performance studies. Select chart values, change the history window and follow a plotted/outlier journey back to the shared debrief. Fitted models and pooled reference diagrams explicitly keep their saved training window. Unavailable studies on the small fixture should explain the missing support.
6. Lab → Fuel & scenarios opens the existing hypothetical controls by default. Switch to History for fill/price/brand exploration, calibration, interval economy and gaps, model evidence/validation, cash-versus-consumption, fuel mix and tank/gauge reconstruction. Switch back to Scenario. Recorded, reconstructed and hypothetical quantities must remain distinguishable.
7. Data quality still lists vehicle observation, collection and analysis times separately. Repeated visits to Today, Trips, Atlas and Lab with unchanged inputs on the same day must not trigger repeated analytical rebuilds. Explicit refresh should complete once; saved edits should publish new values even when trip count stays unchanged. Keep Allow archive changes off for the browsing check.
8. Try light/dark appearance, your normal Dynamic Type size, one larger text setting, and one-handed use with the keyboard visible. Check Atlas controls remain reachable at larger text sizes.

The normal phone navigation no longer opens the desktop Detailed analysis page. Its section-by-section native destinations are documented in [the migration plan](NATIVE_ANALYTICS_MIGRATION.md). The original web files remain the desktop viewer. The new chart cards are in-app tools; Home/Lock Screen system widgets remain a later increment.

Report the phone model/iOS version, screen/action and observed behaviour. Screenshots are helpful if they contain only synthetic records. Do not attach real routes, credentials, personal folder paths or vehicle identifiers to a public issue.

## Live provider testing

Online collection requires the authorized local provider configuration described in the README, plus credentials entered through Settings and stored in Keychain. This first increment has not been accepted against the production provider or on a physical phone. Validate synthetic workflows and the intended archive selection before testing a live sync.
