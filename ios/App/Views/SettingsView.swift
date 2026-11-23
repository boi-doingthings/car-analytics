import SwiftUI

enum InstallInfo {
    /// `ExpirationDate` from the plist embedded in a provisioning-profile (CMS) blob.
    static func expiry(inProfile blob: Data) -> Date? {
        guard let start = blob.range(of: Data("<?xml".utf8)),
              let end = blob.range(of: Data("</plist>".utf8), in: start.lowerBound..<blob.endIndex) else { return nil }
        let plist = blob[start.lowerBound..<end.upperBound]
        guard let obj = try? PropertyListSerialization.propertyList(from: Data(plist), format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }

    /// Device builds: the profile's real expiry. Simulator: executable modification date + 7 days
    /// (it changes on every in-place reinstall).
    static func reinstallDue(bundle: Bundle = .main) -> Date? {
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let blob = try? Data(contentsOf: url), let d = expiry(inProfile: blob) { return d }
        return fallbackDue(executable: bundle.executableURL)
    }

    static func fallbackDue(executable: URL?) -> Date? {
        guard let url = executable,
              let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        return m.addingTimeInterval(7 * 86400)
    }
}

struct SettingsView: View {
    @EnvironmentObject var folder: FolderAccess
    @EnvironmentObject var sync: SyncCoordinator
    @State private var showWriteConsent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Logbook folder") {
                    Text(folder.book?.root.lastPathComponent ?? "None")
                    Button("Re-pick folder") { folder.pick() }
                    if let e = folder.error { Text(e).foregroundStyle(.red) }
                    if let w = folder.warning { Text(w).foregroundStyle(.orange).accessibilityIdentifier("folderWarning") }
                }
                archiveAccessSection
                CredentialsForm()
                LastSyncSection(state: sync.state, canCollect: folder.writesAllowed) {
                    if folder.writesAllowed { sync.syncNow() } else { sync.rebuild() }
                }
                Section("Install") {
                    LabeledContent("Reinstall due") {
                        if let d = InstallInfo.reinstallDue() {
                            Text(d, format: .dateTime.day().month().year())
                        } else {
                            Text("Unknown")
                        }
                    }
                    .accessibilityIdentifier("reinstallDue")
                }
            }
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $folder.showPicker) {
            FolderPicker { folder.picked($0) }
        }
        .alert("Allow changes to this archive?", isPresented: $showWriteConsent) {
            Button("Allow changes") { folder.setWritesAllowed(true) }
                .accessibilityIdentifier("confirmArchiveWrites")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This allows the app to add, edit and delete logbook records and photos, and to save vehicle data when you choose Sync now. Make and verify a separate backup first. Automatic vehicle collection stays off until you enable it separately.")
        }
        .onChange(of: folder.book?.root) { _, _ in showWriteConsent = false }
    }

    private var archiveAccessSection: some View {
        Section {
            Toggle("Allow archive changes", isOn: Binding(
                get: { folder.writesAllowed },
                set: { allow in
                    if allow { showWriteConsent = true }
                    else { folder.setWritesAllowed(false) }
                }))
                .disabled(folder.book == nil)
                .accessibilityIdentifier("archiveWritesToggle")
                .accessibilityHint("Controls adding, editing, deleting and saving vehicle collection to this archive.")
            LabeledContent("Archive access", value: folder.writesAllowed ? "Changes allowed" : "Read-only")
                .accessibilityIdentifier("archiveAccessStatus")
            Toggle("Collect automatically", isOn: Binding(
                get: { folder.automaticSyncEnabled },
                set: { folder.setAutomaticSyncEnabled($0) }))
                .disabled(!folder.writesAllowed)
                .accessibilityIdentifier("automaticCollectionToggle")
                .accessibilityHint("When enabled, the app may collect vehicle data when opened if the last collection is stale.")
        } header: {
            Text("Archive access")
        } footer: {
            Text(folder.writesAllowed
                 ? "Changes are allowed for this archive. Manual collection uses Sync now. Automatic collection is a separate choice and requires working vehicle credentials. Keep a verified backup; cloud synchronization is not a backup."
                 : "Read-only keeps your archive unchanged. You can browse records and rebuild analysis in this app’s local cache. Enable changes only when you want to add, edit or delete records, or save new vehicle collection. Make and verify a separate backup first.")
        }
    }
}

struct LastSyncSection: View {
    let state: SyncState
    let canCollect: Bool
    let syncNow: () -> Void

    init(state: SyncState, canCollect: Bool = true, syncNow: @escaping () -> Void) {
        self.state = state
        self.canCollect = canCollect
        self.syncNow = syncNow
    }

    static let stepLabels = ["check": "Checking archive for changes…", "login": "Logging in to Bluelink\u{2026}", "collect": "Fetching from Hyundai\u{2026}",
                             "analyse": "Recalculating\u{2026}"]

    var body: some View {
        Section("Last sync") {
            if state.running {
                Label(Self.stepLabels[state.step ?? ""] ?? "Syncing\u{2026}", systemImage: "arrow.triangle.2.circlepath")
            } else if let last = state.lastSync {
                LabeledContent("Synced") { Text(last, format: .dateTime.day().month().hour().minute()) }
            } else {
                Text("No sync yet")
            }
            if let e = state.error { Text(e).foregroundStyle(.red).accessibilityIdentifier("syncError") }
            if let s = state.stats {
                LabeledContent("Days fetched / already final", value: "\(s.daysFetched) / \(s.daysSkipped)")
                LabeledContent("Trips fetched / kept", value: "\(s.tripsFetched) / \(s.tripsSkipped)")
            }
            Button(canCollect ? "Sync now" : "Rebuild analysis", action: syncNow)
                .disabled(state.running)
                .accessibilityIdentifier("syncOrRebuildButton")
        }
        if !state.issues.isEmpty {
            Section("Sync issues (\(state.issues.count))") {
                ForEach(Array(state.issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue).font(.footnote).foregroundStyle(.orange)
                }
            }
        }
    }
}
