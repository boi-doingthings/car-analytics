# Use real car history with the v2 app

Use the latest `codex/v2-native-foundation` build. Newly selected or restored archives start read-only unless you have previously enabled changes for that exact archive on this device. Automatic vehicle collection is a separate opt-in and defaults off.

## Recommended sequence

1. Make and verify a separate backup of the fully downloaded main `i20_book`. Pause other writers while backing it up. Keep the backup outside Git and outside the live archive.
2. Rebuild/install the latest branch. In Settings, re-pick the main `i20_book`; leave **Allow archive changes** off. Check the **Read-only** indicator before browsing your real history.
3. Confirm the trip/refuel/service history and latest observations look right. Rebuilding analysis writes only rebuildable app-local outputs, not records in the selected archive.
4. When ready to log against the main archive, enable **Allow archive changes** in Settings. Use one active writer and keep **Collect automatically** off until the first controlled provider sync has been tested on a copy.

A picker selection does not migrate, clear or rewrite the existing archive. Imported records with an ID that disagrees with their filename are skipped and reported rather than edited under another record’s ID.

### Access modes

| Setting | Behaviour |
|---|---|
| Changes off | Browse records and rebuild app-local analysis; archive record/photo writes, deletion and vehicle collection are blocked |
| Changes on, automatic collection off | Add/edit/delete records; explicit Sync now or pull-to-refresh can collect vehicle data |
| Changes on, automatic collection on | Checks on opening/foregrounding; collects when the last sync is over 12 hours old |

Permission is enforced by the archive writer itself, not only by disabled UI controls. Turning changes off revokes existing writer references. An already-started provider request may finish, but subsequent archive writes and provider requests are blocked after revocation.

### Live collection setup and retention

Saved account credentials and provider configuration are separate. The device Keychain holds the username/password. The locally built app also needs the four provider settings in the Git-ignored `ios/App/Resources/Bluelink.local.plist`, copied from the example and populated using authorized local configuration. Regenerate the Xcode project and rebuild after adding that file. A missing-configuration error happens before the login network request and does not establish whether the account credentials are correct. Never commit the local plist or distribute a build containing it as a public artifact.

Automatic collection currently runs only on eligible foreground events, with a 12-hour stale threshold. There is no after-drive trigger or background collection while the app is closed. Use Sync now to request newer provider data sooner; availability still depends on Hyundai returning the new trips.

The collector does not delete raw history. It adds timestamped snapshots and missing responses, but the archive is not an immutable record of every fetched revision: non-final day responses can be replaced, and routes with at most one point can be refreshed for non-final days. A day is final once its successful fetch was at least seven India-calendar days after that day; finalized day files are not overwritten. Collection also updates sidecars and sync state.

Manual deletion is available for refuel/service/expense records in Garage → Open logbook. Deleting a service also removes its associated photo folder; editing a service can remove photos that were deselected. Failed service saves can clean up newly written attachments. These operations target `log/`, not the collector's `raw/` history. Old app-local analytical generations are also pruned; those are rebuildable caches outside the selected archive.

## Create and verify a backup

The standard-library tool `tools/archive_backup.py` copies bytes and preserves original file modification times, writes a checksum manifest, verifies the copied tree and refuses an existing destination. It rejects symbolic links and undownloaded `.icloud` placeholders and detects ordinary source changes during the copy. A backup cannot be created inside any Git checkout.

Replace the placeholders with private local locations; do not commit those locations or the resulting backup:

```sh
python3 tools/archive_backup.py create \
  --book "<existing archive parent>/i20_book" \
  --out "<new private backup folder>"

python3 tools/archive_backup.py verify \
  --backup "<private backup folder>"
```

For a restore rehearsal, restore into a new location rather than the live archive:

```sh
python3 tools/archive_backup.py restore \
  --backup "<private backup folder>" \
  --out "<new private verification parent>/i20_book"
```

Do not treat cloud synchronization as an independent backup. Keep an independent copy and confirm a restore before relying on it. Backups are private: the manifest contains record filenames, and the copied records/photos contain the original data.

## What is and is not accepted yet

The native UI and a fuel-save workflow have user-reported smoke-test feedback. The safety gates, ID checks and backup/restore operations have synthetic regression tests. These do not establish live-provider or all-device acceptance.

Browse and additive logging are the recommended first main-archive operations after backup. Editing/deleting still lacks disk-level optimistic concurrency and an undo/recovery history; avoid simultaneous edits from another device. A first live provider sync should run against a copy: collection intentionally updates recent non-final responses and writes sync state, even though it sends no vehicle-control commands.

Keep the earlier test archive until any real fuel entry you put there has been carried across. Switching folders does not merge records. An existing migrated archive does not need the migration tool rerun just to open it.
