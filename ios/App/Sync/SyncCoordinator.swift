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
    /// Publication time of the last complete analytical generation on this device.
    var lastAnalysis: Date?
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
    /// Bumped after a sequence publishes data, including a local rebuild following a failed login.
    @Published private(set) var finishedRuns = 0

    private let book: () -> Book?
    private let credentials: () -> (String, String)?
    private let login: Login
    private let runner: AnalyticsRunner
    private let now: () -> Date
    private let collectorPause: Duration
    private let automaticCollection: () -> Bool
    private var rebuildPending = false

    init(book: @escaping () -> Book?,
         credentials: @escaping () -> (String, String)? = { Credentials.load() },
         login: @escaping Login = SyncCoordinator.liveLogin,
         runner: AnalyticsRunner = AnalyticsRunner(),
         now: @escaping () -> Date = Date.init,
         collectorPause: Duration = .milliseconds(600),
         automaticCollection: @escaping () -> Bool = { true }) {
        self.book = book
        self.credentials = credentials
        self.login = login
        self.runner = runner
        self.now = now
        self.collectorPause = collectorPause
        self.automaticCollection = automaticCollection
        self.state.lastAnalysis = book().flatMap { runner.matches($0) ? runner.publishedAt : nil }
    }

    static func liveLogin(username: String, password: String) async throws -> BluelinkAPI {
        let client = BluelinkClient(session: URLSession(configuration: .ephemeral))
        try await client.login(username: username, password: password)
        return client
    }

    /// Never expose another selected archive's cached values as this archive's data.
    var derivedDir: URL {
        guard let selected = book() else { return runner.derivedDir }
        return runner.matches(selected) ? runner.derivedDir : runner.unavailableDirectory(for: selected)
    }
    var hasCurrentArchiveSnapshot: Bool { book().map { runner.matches($0) } ?? false }
    var archiveAllowsChanges: Bool { book()?.canWrite == true }

    /// Re-reads `state/last_sync.json` from the book (no wait for an iCloud download).
    func refreshLastSync() {
        guard let book = book(), let data = try? book.read("state/last_sync.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["last_sync"] as? String else { state.lastSync = nil; return }
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

    /// Automatically collect only with write consent, automatic-sync consent and saved credentials.
    /// Otherwise check whether the cached analysis needs rebuilding. Passive events never queue work
    /// behind an already active run.
    func syncIfStale() {
        guard !state.running else { return }
        guard book()?.canWrite == true, automaticCollection(), credentials() != nil else {
            rebuildIfNeeded()
            return
        }
        refreshLastSync()
        if let last = state.lastSync, now().timeIntervalSince(last) <= Self.staleAfter {
            rebuildIfNeeded()
        } else {
            syncNow()
        }
    }

    /// login → collect → analyse. No-op while a run is going.
    func syncNow() {
        guard !state.running else { return }
        guard book()?.canWrite != false else { rebuild(); return }
        begin(step: "login")
        state.stats = nil  // a full sync replaces the summary; an analytics-only rebuild keeps the last one
        task = Task { await self.runSequence(collect: true) }
    }

    /// Coalesce edits arriving during a run, then rebuild from the latest saved archive before
    /// completing the same task. Callers awaiting task.value also await this follow-up work.
    func rebuild() {
        if state.running {
            rebuildPending = true
            return
        }
        begin(step: "analyse")
        task = Task { await self.runSequence(collect: false) }
    }

    /// Idempotent lifecycle refresh. An event arriving during any current operation is already
    /// covered by that operation; it must not queue the forced follow-up reserved for saved edits.
    func rebuildIfNeeded() {
        guard !state.running else { return }
        begin(step: "check")
        task = Task { await self.runSequence(collect: false, onlyIfNeeded: true) }
    }

    private func runSequence(collect: Bool, onlyIfNeeded: Bool = false) async {
        var error: String?
        var published = false
        var collectionFailed = false
        do {
            if collect {
                try await fullSync()
                published = true
            } else {
                guard let book = book() else { throw BookError.unreachable }
                published = try await analyse(book, collectorIssues: [], onlyIfNeeded: onlyIfNeeded)
            }
        } catch let failure {
            error = Self.text(for: failure)
            collectionFailed = collect
        }
        while rebuildPending && !Task.isCancelled {
            rebuildPending = false
            state.step = "analyse"
            do {
                guard let book = book() else { throw BookError.unreachable }
                published = try await analyse(book, collectorIssues: state.stats?.errors ?? []) || published
                if !collectionFailed { error = nil }
            } catch let failure {
                error = Self.text(for: failure)
            }
        }
        rebuildPending = false
        finish(error: error, published: published)
    }

    private func begin(step: String) {
        state.running = true
        state.step = step
        state.error = nil
        state.lastAnalysis = hasCurrentArchiveSnapshot ? runner.publishedAt : nil
        refreshLastSync()
        if !hasCurrentArchiveSnapshot { state.stats = nil }
        // An aborted run must not show the previous run's numbers.
        state.issues = []
    }

    private func fullSync() async throws {
        guard let book = book() else { throw BookError.unreachable }
        _ = try book.list("")  // folder reachable before any network call
        guard book.canWrite else { throw BookError.readOnly }
        guard let (user, pass) = credentials() else { throw BluelinkError.loginFailed }
        guard book.canWrite else { throw BookError.readOnly }
        let api = try await login(user, pass)
        guard book.canWrite else { throw BookError.readOnly }
        state.step = "collect"
        let protectedAPI = ArchiveAuthorizedAPI(book: book, api: api)
        let stats = try await Collector(book: book, api: protectedAPI, now: { Date() }, pause: collectorPause).run()
        state.stats = stats
        refreshLastSync()
        state.step = "analyse"
        _ = try await analyse(book, collectorIssues: stats.errors)
    }

    private func analyse(_ book: Book, collectorIssues: [String], onlyIfNeeded: Bool = false) async throws -> Bool {
        let runner = self.runner
        let today = AnalyticsRunner.istDay(now())
        defer { state.issues = collectorIssues + runner.issues }
        let published: Bool
        if onlyIfNeeded {
            published = try await runner.runIfNeeded(book: book, today: today) { [weak self] in
                await MainActor.run { self?.state.step = "analyse" }
            }
        } else { _ = try await runner.run(book: book, today: today); published = true }
        if self.book()?.root != book.root { rebuildPending = true }
        state.lastAnalysis = hasCurrentArchiveSnapshot ? runner.publishedAt : nil
        refreshLastSync()
        return published
    }

    private func finish(error: String?, published: Bool) {
        state.running = false
        state.step = nil
        state.error = error
        if published { finishedRuns += 1 }
    }

    static func text(for error: Error) -> String {
        switch error {
        case BluelinkError.timeout: return timeoutText
        case BluelinkError.loginFailed: return loginText
        case BookError.readOnly: return "This archive is read-only. Rebuild its analysis, or enable archive changes in Settings."
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

/// A permission revocation stops subsequent collector requests as well as archive writes. A request
/// already in flight may complete, but Book's shared policy still rejects any later mutation.
private struct ArchiveAuthorizedAPI: BluelinkAPI {
    let book: Book
    let api: BluelinkAPI

    func vehicles() async throws -> (raw: Data, list: [Vehicle]) {
        guard book.canWrite else { throw BookError.readOnly }
        return try await api.vehicles()
    }

    func get(_ path: String) async throws -> Data {
        guard book.canWrite else { throw BookError.readOnly }
        return try await api.get(path)
    }

    func post(_ path: String, json: [String: Any]) async throws -> Data {
        guard book.canWrite else { throw BookError.readOnly }
        return try await api.post(path, json: json)
    }
}
