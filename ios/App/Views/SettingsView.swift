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

    var body: some View {
        NavigationStack {
            Form {
                Section("Logbook folder") {
                    Text(folder.book?.root.lastPathComponent ?? "None")
                    Button("Re-pick folder") { folder.pick() }
                    if let e = folder.error { Text(e).foregroundStyle(.red) }
                    if let w = folder.warning { Text(w).foregroundStyle(.orange).accessibilityIdentifier("folderWarning") }
                }
                CredentialsForm()
                LastSyncSection(state: sync.state) { sync.syncNow() }
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
    }
}

struct LastSyncSection: View {
    let state: SyncState
    let syncNow: () -> Void

    static let stepLabels = ["login": "Logging in to Bluelink\u{2026}", "collect": "Fetching from Hyundai\u{2026}",
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
            Button("Sync now", action: syncNow).disabled(state.running)
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
