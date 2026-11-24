import SwiftUI

/// A single native navigation hierarchy over one complete analytical generation.
struct NativeWorkspace: View {
    @EnvironmentObject private var folder: FolderAccess
    @EnvironmentObject private var sync: SyncCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: AnalyticsSnapshot?
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var loadRevision = 0
    @State private var selectedTab: Int = {
        #if DEBUG
        if DebugHarness.active, let raw = ProcessInfo.processInfo.environment["I20_DEBUG_TAB"],
           let tab = Int(raw), (0...4).contains(tab) { return tab }
        #endif
        return 0
    }()

    var body: some View {
        VStack(spacing: 0) {
            notices
            TabView(selection: $selectedTab) {
                NativeHomeView(snapshot: snapshot, onSettings: { showSettings = true })
                    .tabItem { Label("Today", systemImage: "gauge.with.dots.needle.33percent") }
                    .tag(0)
                    .accessibilityIdentifier("todayScreen")
                NativeTripsView(snapshot: snapshot, onSettings: { showSettings = true })
                    .tabItem { Label("Trips", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                    .tag(1)
                NativeAtlasView(snapshot: snapshot, onSettings: { showSettings = true })
                    .tabItem { Label("Atlas", systemImage: "map") }
                    .tag(4)
                NativeGarageView(snapshot: snapshot, onSettings: { showSettings = true })
                    .tabItem { Label("Garage", systemImage: "car.side") }
                    .tag(2)
                NativeLabView(snapshot: snapshot, onSettings: { showSettings = true })
                    .tabItem { Label("Lab", systemImage: "waveform.path.ecg") }
                    .tag(3)
            }
            // Changing archives discards retained navigation stacks and their previous archive views.
            .id(folder.book?.root)
        }
        .tint(NativeTheme.accent)
        .sheet(isPresented: $showSettings, onDismiss: startRefresh) {
            SettingsView()
                .safeAreaInset(edge: .top) {
                    HStack {
                        Spacer()
                        Button("Done") { showSettings = false }.padding(.horizontal)
                    }.padding(.top, 8).background(.regularMaterial)
                }
        }
        .task(id: loadRevision) { await loadSnapshot() }
        .task(id: folder.book?.root) {
            snapshot = nil
            loadError = nil
            loadRevision += 1
            // Re-picking an archive must invalidate the old archive’s read models immediately.
            startRefresh()
        }
        .onChange(of: sync.finishedRuns) { _, _ in loadRevision += 1 }
        .onChange(of: folder.automaticSyncEnabled) { _, enabled in if enabled { startRefresh() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { startRefresh() } }
    }

    /// A sibling reserves real layout space; an inset on TabView can cover pushed navigation bars.
    private var notices: some View {
        VStack(spacing: 0) {
            if folder.book != nil && !folder.writesAllowed {
                HStack(spacing: 8) {
                    Image(systemName: "lock").accessibilityHidden(true)
                    Text("Read-only archive")
                        .font(.caption.weight(.medium))
                        .accessibilityIdentifier("archiveReadOnlyBanner")
                    Spacer(minLength: 0)
                    Button { showSettings = true } label: {
                        Text("Manage access")
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("manageArchiveAccess")
                }
                .padding(.horizontal, 16)
                .background(.regularMaterial)
            }
            if let loadError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(loadError).font(.caption)
                    Spacer(minLength: 0)
                    Button("Retry") { loadRevision += 1 }
                }
                .padding(12)
                .background(.regularMaterial)
                .accessibilityIdentifier("snapshotError")
            }
        }
    }

    private func startRefresh() {
        // Passive lifecycle requests share the coordinator's cache/collection policy.
        // User refreshes and saved edits still explicitly force a rebuild.
        sync.syncIfStale()
    }

    @MainActor
    private func loadSnapshot() async {
        let archive = folder.book?.root
        let directory = sync.derivedDir
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try AnalyticsSnapshot.load(from: directory)
            }.value
            try Task.checkCancellation()
            guard folder.book?.root == archive else { return }
            snapshot = loaded
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, folder.book?.root == archive else { return }
            // No output is expected on first launch. Preserve any previous in-memory snapshot.
            let hasOutput = FileManager.default.fileExists(atPath: directory.appending(path: "data.json").path)
            loadError = hasOutput ? "The saved analysis couldn’t be opened. Your logbook is unchanged. Try rebuilding in Settings." : nil
        }
    }
}
