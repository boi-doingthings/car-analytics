import Foundation
import I20Core

struct SyncState: Equatable {
    var running = false
    /// `login` → `collect` → `analyse` while running (web/common.js maps these to labels).
    var step: String?
    /// Header text for the last failure, nil after a clean run.
    var error: String?
    /// From `state/last_sync.json` in the book (written by the collector).
    var lastSync: Date?
    /// Non-fatal problems of the last run: collector errors, analytics errors, skipped files/entries.
    var issues: [String] = []
    /// Collector summary of the last full sync.
    var stats: CollectStats?
}

/// Runs a sync (Bluelink login → collector into the book → analytics into derived/) and publishes its
/// state for the header label (via the scheme handler) and Settings.
@MainActor
final class SyncCoordinator: ObservableObject {
    typealias Login = (_ username: String, _ password: String) async throws -> BluelinkAPI

    static let staleAfter: TimeInterval = 12 * 3600
    static let timeoutText = "Hyundai's server didn't respond. Try again in a few minutes."
    static let loginText = "Bluelink login failed. Check your username and password in Settings."
    static let folderText = "Can't reach the i20_book folder in iCloud Drive."

    @Published private(set) var state = SyncState()
    /// The running sync/rebuild (tests await it).
    private(set) var task: Task<Void, Never>?
    /// Bumped when a run finishes without error, so the dashboard can reload.
    @Published private(set) var finishedRuns = 0

    private let book: () -> Book?
    private let credentials: () -> (String, String)?
    private let login: Login
    private let runner: AnalyticsRunner
    private let now: () -> Date
    private let collectorPause: Duration

    init(book: @escaping () -> Book?,
         credentials: @escaping () -> (String, String)? = { Credentials.load() },
         login: @escaping Login = SyncCoordinator.liveLogin,
         runner: AnalyticsRunner = AnalyticsRunner(),
         now: @escaping () -> Date = Date.init,
         collectorPause: Duration = .milliseconds(600)) {
        self.book = book
        self.credentials = credentials
        self.login = login
        self.runner = runner
        self.now = now
        self.collectorPause = collectorPause
    }

    static func liveLogin(username: String, password: String) async throws -> BluelinkAPI {
        let client = BluelinkClient(session: URLSession(configuration: .ephemeral))
        try await client.login(username: username, password: password)
        return client
    }

    var derivedDir: URL { runner.derivedDir }

    /// Re-reads `state/last_sync.json` from the book (no wait for an iCloud download).
    func refreshLastSync() {
        guard let book = book(), let data = try? book.read("state/last_sync.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["last_sync"] as? String else { return }
        state.lastSync = Self.parseISO(s)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        // Naive timestamps are IST.
        let n = DateFormatter()
        n.locale = Locale(identifier: "en_US_POSIX")
        n.timeZone = TimeZone(identifier: "Asia/Kolkata")
        n.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return n.date(from: s)
    }

    /// Full sync when the last one is older than 12 h (or unknown); otherwise rebuilds the analytics if
    /// derived/ has no dashboard yet. Does nothing while a run is going.
    func syncIfStale() {
        guard !state.running else { return }
        refreshLastSync()
        if let last = state.lastSync, now().timeIntervalSince(last) <= Self.staleAfter {
            if !FileManager.default.fileExists(atPath: derivedDir.appending(path: "data.json").path) { rebuild() }
        } else {
            syncNow()
        }
    }

    /// login → collect → analyse. No-op while a run is going.
    func syncNow() {
        guard !state.running else { return }
        begin(step: "login")
        state.stats = nil  // a full sync replaces the summary; an analytics-only rebuild keeps the last one
        task = Task { await self.fullSync() }
    }

    /// Analytics only (after a log edit). No-op while a run is going.
    func rebuild() {
        guard !state.running else { return }
        begin(step: "analyse")
        task = Task {
            do {
                guard let book = self.book() else { throw BookError.unreachable }
                try await self.analyse(book, collectorIssues: [])
                self.finish(error: nil)
            } catch {
                self.finish(error: Self.text(for: error))
            }
        }
    }

    private func begin(step: String) {
        state.running = true
        state.step = step
        state.error = nil
        // An aborted run must not show the previous run's numbers.
        state.issues = []
    }

    private func fullSync() async {
        do {
            guard let book = book() else { throw BookError.unreachable }
            _ = try book.list("")  // folder reachable before any network call
            guard let (user, pass) = credentials() else { throw BluelinkError.loginFailed }
            let api = try await login(user, pass)
            state.step = "collect"
            let stats = try await Collector(book: book, api: api, now: { Date() }, pause: collectorPause).run()
            state.stats = stats
            refreshLastSync()
            state.step = "analyse"
            try await analyse(book, collectorIssues: stats.errors)
            finish(error: nil)
        } catch {
            finish(error: Self.text(for: error))
        }
    }

    private func analyse(_ book: Book, collectorIssues: [String]) async throws {
        let runner = self.runner
        let today = AnalyticsRunner.istDay(now())
        defer { state.issues = collectorIssues + runner.issues }
        _ = try await runner.run(book: book, today: today)
    }

    private func finish(error: String?) {
        state.running = false
        state.step = nil
        state.error = error
        if error == nil { finishedRuns += 1 }
    }

    static func text(for error: Error) -> String {
        switch error {
        case BluelinkError.timeout: return timeoutText
        case BluelinkError.loginFailed: return loginText
        // Book reads/writes (the collector's and the runner's) are the only file operations that throw
        // these; derived/ writes surface as AnalyticsError.saveFailed.
        case is BookError, is CocoaError: return folderText
        case let e as AnalyticsError: return e.errorDescription ?? folderText
        case BluelinkError.badResponse(let m): return "Sync failed: Hyundai's server sent an unexpected reply (\(m))."
        case is CancellationError: return "Sync cancelled."
        default: return "Sync failed: \(error.localizedDescription)"
        }
    }
}
