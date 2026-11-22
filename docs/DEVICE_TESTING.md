# Test the native v2 increment

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
git switch codex/v2-native-foundation
npm ci --prefix analytics
npm run build --prefix analytics
cd ios
xcodegen generate
open I20Logbook.xcodeproj
```

Use the `I20Logbook` scheme. For a simulator, select an available iPhone and Run. For a physical phone, connect/pair it in Xcode, select it as the destination, choose your own team under Signing & Capabilities, and enable Developer Mode if the phone requests it. The app requires iOS 18 or later. Keep signing settings local; do not commit team identifiers, generated project files, credentials or provider configuration.

## First physical-device check with synthetic data

Copy the repository’s `ios/Tests/Fixtures/book` folder into a new test location in iCloud Drive using Finder. Rename only the copy to `i20_book`. Pick that copied folder in the app. These invented records include historical dates, so an empty recent 7-day briefing is expected; the historical journeys remain available under Trips.

This build uses the existing application bundle identifier, so installing it updates the installed app rather than adding a second app. It can retain the previous archive bookmark and Keychain login.

For this initial visual/offline check, keep the phone offline before the first launch, after the copied folder has downloaded. If an existing archive is restored, use Settings → Logbook folder → Re-pick folder to choose the test copy before adding or changing records. No Bluelink credentials are needed to rebuild and browse an existing archive. This also prevents an existing Keychain login from beginning an online collection into the test copy. The authoritative original archive stays outside the app and should remain unchanged by these test edits.

Check the following:

1. Today fits comfortably, larger text remains readable, and switching between 7/30/90 days is clear. Old vehicle readings must be labelled historical.
2. Trips can be searched by place/date, filtered, opened and navigated back from. Route geometry should remain viewable when map tiles are unavailable.
3. Garage opens the editable logbook. Add a clearly named test refuel with a typed odometer, edit it and delete it. Confirm that only the copied archive changed.
4. Lab opens the scenario calculator and Data quality. Hypothetical inputs, estimated values and unknown values should be distinguishable.
5. Pull to refresh and opening Settings should not freeze scrolling or strand the interface in a spinner. After changing a record, the next complete analysis should reflect it.
6. Try light/dark appearance, your normal Dynamic Type size, one larger text setting, and one-handed use with the keyboard visible.

Report the phone model/iOS version, screen/action and observed behaviour. Screenshots are helpful if they contain only synthetic records. Do not attach real routes, credentials, personal folder paths or vehicle identifiers to a public issue.

## Live provider testing

Online collection requires the authorized local provider configuration described in the README, plus credentials entered through Settings and stored in Keychain. This first increment has not been accepted against the production provider or on a physical phone. Validate synthetic workflows and the intended archive selection before testing a live sync.
