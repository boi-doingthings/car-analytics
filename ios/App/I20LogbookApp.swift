import SwiftUI
import I20Core

@main
struct I20LogbookApp: App {
    @StateObject private var folder: FolderAccess
    @StateObject private var sync: SyncCoordinator

    init() {
        let folder = FolderAccess()
        _folder = StateObject(wrappedValue: folder)
        #if DEBUG
        if let harness = DebugHarness.fromEnvironment() {
            folder.book = harness.book
            _sync = StateObject(wrappedValue: SyncCoordinator(book: { folder.book }, credentials: { ("debug", "debug") },
                                                              login: harness.login))
            return
        }
        #endif
        _sync = StateObject(wrappedValue: SyncCoordinator(book: { folder.book }))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(folder)
                .environmentObject(sync)
                .onAppear {
                    folder.restore()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var folder: FolderAccess
    @State private var hasCredentials = Credentials.load() != nil || DebugHarness.active

    var body: some View {
        if folder.book == nil {
            SetupView(hasCredentials: $hasCredentials)
        } else {
            NativeWorkspace()
        }
    }
}
