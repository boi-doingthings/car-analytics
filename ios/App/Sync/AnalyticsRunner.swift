import Foundation
import CryptoKit
import JavaScriptCore
import os
import I20Core

enum AnalyticsError: Error, Equatable, LocalizedError {
    case bundleMissing
    case script(String)
    /// The overview or performance output could not be built; messages from `runAll().errors`.
    case failed([String])
    /// Some book files are still iCloud placeholders; nothing was written so the last good dashboard stays.
    case stillDownloading(Int)
    /// Writing derived/ on this device failed.
    case saveFailed(String)
    /// Inputs changed while being read; never certify a generation against newer, unanalysed files.
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .bundleMissing: "analytics.js is missing from the app"
        case .script(let m): "Analytics script error: \(m)"
        case .failed(let ms): "Analysis failed: " + ms.joined(separator: "; ")
        case .stillDownloading(let n): "\(n) file\(n == 1 ? "" : "s") still downloading from iCloud \u{2014} sync again shortly."
        case .saveFailed(let m): "Couldn't save the dashboard on this iPhone (\(m))."
        case .sourceChanged: "The archive changed while analysis was running. Refresh after it finishes syncing."
        }
    }
}

/// Runs the bundled analytics (`analytics.js`, `I20Analytics.runAll`) over the book and writes `data.json`,
/// `fuel.json` and `performance.json` to `derivedDir` (Application Support/derived). Reads the book only;
/// never writes into it.
final class AnalyticsRunner {
    static let defaultDerivedDir: URL =
        URL.applicationSupportDirectory.appending(path: "derived", directoryHint: .isDirectory)
    /// How long to wait for one iCloud placeholder to download.
    static let defaultDownloadTimeout: TimeInterval = 30

    private let storageRoot: URL
    private let worker = AnalyticsWorker()
    var derivedDir: URL { AnalyticsGeneration(root: storageRoot).directory }
    var publishedAt: Date? { AnalyticsGeneration(root: storageRoot).manifest?.publishedAt }
    func matches(_ book: Book) -> Bool {
        AnalyticsGeneration(root: storageRoot).manifest?.archiveID == AnalyticsGeneration.archiveID(for: book.root)
    }
    func unavailableDirectory(for book: Book) -> URL {
        storageRoot.appending(path: "unavailable", directoryHint: .isDirectory)
            .appending(path: AnalyticsGeneration.archiveID(for: book.root), directoryHint: .isDirectory)
    }
    let script: URL?
    private let beforePublication: (@Sendable () throws -> Void)?
    /// How long to wait for one iCloud placeholder to download.
    var downloadTimeout: TimeInterval = AnalyticsRunner.defaultDownloadTimeout
    /// Problems of the last run (reset at its start): analytics page errors, raw files that couldn't be read or
    /// parsed, log entries skipped (newer schema / unreadable); or, when it threw `.stillDownloading`, the
    /// files still waiting for iCloud.
    private(set) var issues: [String] = []

    init(derivedDir: URL = AnalyticsRunner.defaultDerivedDir,
         script: URL? = Bundle.main.url(forResource: "analytics", withExtension: "js"),
         beforePublication: (@Sendable () throws -> Void)? = nil) {
        self.storageRoot = derivedDir
        self.script = script
        self.beforePublication = beforePublication
    }

    /// `YYYY-MM-DD` in Asia/Kolkata, whatever the device's time zone.
    static func istDay(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func run(book: Book, today: String) async throws -> (data: Data, fuel: Data?, performance: Data) {
        issues = []
        let result = await worker.perform(book: book, today: today, script: script,
                                          storageRoot: storageRoot, downloadTimeout: downloadTimeout,
                                          onlyIfNeeded: false, beforePublication: beforePublication, onRebuild: nil)
        issues = result.issues
        guard let output = try result.output.get() else { throw AnalyticsError.failed(["no output"]) }
        return output
    }

    /// Passive lifecycle refresh: metadata checks run on the worker, with no provider or archive writes.
    /// Returns true only when a new complete generation was published.
    func runIfNeeded(book: Book, today: String,
                     onRebuild: (@Sendable () async -> Void)? = nil) async throws -> Bool {
        let result = await worker.perform(book: book, today: today, script: script,
                                          storageRoot: storageRoot, downloadTimeout: downloadTimeout,
                                          onlyIfNeeded: true, beforePublication: beforePublication, onRebuild: onRebuild)
        switch result.output {
        case .success(nil): return false  // Keep current diagnostic warnings as well as the cached data.
        case .success: issues = result.issues; return true
        case .failure(let error): issues = result.issues; throw error
        }
    }

    /// Skipped-entry warnings from the analytics ("skipping entry <id>: reason") that `skippedEntries` hasn't
    /// already reported under the entry's file name.
    static func newWarnings(_ warnings: [String], besides issues: [String]) -> [String] {
        warnings.filter { w in
            guard w.hasPrefix("skipping entry "), let colon = w.firstIndex(of: ":") else { return true }
            let id = w[w.index(w.startIndex, offsetBy: "skipping entry ".count)..<colon]
            return id == "?" || !issues.contains { $0.contains("/\(id).json") }
        }
    }

    /// A kind whose folder can't be listed/read here (e.g. an entry left as a placeholder, already reported
    /// above) contributes nothing.
    fileprivate static func skippedEntries(_ book: Book) -> [String] {
        func describe(_ kind: EntryKind, _ s: [SkippedEntry]) -> [String] {
            s.map { e in
                switch e.reason {
                case .newerSchema(let v): "\(kind.dir)/\(e.name): written by a newer app (schema \(v)), left out"
                case .unreadable: "\(kind.dir)/\(e.name): couldn't be read, left out"
                case .badName: "\(kind.dir)/\(e.name): not an entry file (a duplicate or stray file), left out"
                }
            }
        }
        return describe(.refuel, (try? loadAll(Refuel.self, from: book))?.skipped ?? [])
            + describe(.service, (try? loadAll(ServiceVisit.self, from: book))?.skipped ?? [])
            + describe(.maintenance, (try? loadAll(Maintenance.self, from: book))?.skipped ?? [])
    }
}

private struct AnalyticsRunResult {
    let output: Result<(data: Data, fuel: Data?, performance: Data)?, Error>
    let issues: [String]
}

private actor AnalyticsWorker {
    private var issues: [String] = []
    private static let log = Logger(subsystem: "com.i20logbook.app", category: "analytics-worker")

    func perform(book: Book, today: String, script: URL?, storageRoot: URL,
                 downloadTimeout: TimeInterval, onlyIfNeeded: Bool,
                 beforePublication: (@Sendable () throws -> Void)?,
                 onRebuild: (@Sendable () async -> Void)?) async -> AnalyticsRunResult {
        issues = []
        do {
            let out = try await run(book: book, today: today, script: script,
                                    storageRoot: storageRoot, downloadTimeout: downloadTimeout,
                                    onlyIfNeeded: onlyIfNeeded, beforePublication: beforePublication, onRebuild: onRebuild)
            return AnalyticsRunResult(output: .success(out), issues: issues)
        } catch {
            return AnalyticsRunResult(output: .failure(error), issues: issues)
        }
    }

    private func run(book: Book, today: String, script: URL?, storageRoot: URL, downloadTimeout: TimeInterval,
                     onlyIfNeeded: Bool, beforePublication: (@Sendable () throws -> Void)?,
                     onRebuild: (@Sendable () async -> Void)?) async throws
        -> (data: Data, fuel: Data?, performance: Data)? {
        guard let script, let scriptData = try? Data(contentsOf: script),
              let source = String(data: scriptData, encoding: .utf8) else {
            throw AnalyticsError.bundleMissing
        }
        var issues: [String] = []
        let started = Date()
        let scriptDigest = Self.digest(scriptData)
        let initial = try inputSnapshot(book)
        let inputs = AnalyticsGeneration.Inputs(signature: initial.signature, day: today, scriptDigest: scriptDigest)
        let store = AnalyticsGeneration(root: storageRoot)
        if onlyIfNeeded, let manifest = store.manifest,
           manifest.archiveID == AnalyticsGeneration.archiveID(for: book.root), manifest.inputs == inputs,
           let files = manifest.files, Set(files).count == files.count,
           Set(files).isSubset(of: ["data.json", "performance.json", "fuel.json"]),
           Set(files).isSuperset(of: ["data.json", "performance.json"]), !initial.hasPlaceholders,
           files.allSatisfy({
               let attributes = try? FileManager.default.attributesOfItem(atPath: store.directory.appending(path: $0).path)
               return attributes?[.type] as? FileAttributeType == .typeRegular
           }) {
            return nil
        }

        await onRebuild?()
        try Task.checkCancellation()
        // Download the initial JSON set, then capture the exact local metadata that will be analysed.
        let paths = initial.paths
        let timeout = downloadTimeout
        // Bound cloud requests: a large archive must not create thousands of simultaneous tasks.
        let missing = await withTaskGroup(of: String?.self) { group in
            var pending = paths.makeIterator()
            func add(_ path: String) {
                group.addTask {
                    do { try await book.ensureDownloaded(path, timeout: timeout); return nil }
                    catch { return path }
                }
            }
            for _ in 0..<min(4, paths.count) { if let p = pending.next() { add(p) } }
            var out = Set<String>()
            for await p in group {
                if let p { out.insert(p) }
                if let next = pending.next(), !Task.isCancelled { add(next) }
            }
            return out
        }
        try Task.checkCancellation()
        // A partial archive would overwrite good numbers with wrong ones: keep the last outputs instead.
        if !missing.isEmpty {
            self.issues = missing.sorted().map { "\($0): still downloading from iCloud" }
            throw AnalyticsError.stillDownloading(missing.count)
        }

        let analysed = try inputSnapshot(book)
        guard analysed.paths == paths, !analysed.hasPlaceholders else { throw AnalyticsError.sourceChanged }
        let analysedInputs = AnalyticsGeneration.Inputs(signature: analysed.signature, day: today, scriptDigest: scriptDigest)

        // Log entries Swift can't read (newer schema, bad shape) are listed; the JS skips newer schemas too.
        issues += AnalyticsRunner.skippedEntries(book)

        // 2. Evaluate the bundle and hand it the files.
        let ctx: JSContext = JSContext()
        var jsError: String?
        ctx.exceptionHandler = { _, e in jsError = e?.toString() ?? "unknown error" }
        ctx.evaluateScript(source)
        ctx.evaluateScript("""
            globalThis.__files = {};
            globalThis.__add = function (k, text) {
              try { __files[k] = JSON.parse(text); return true; } catch (e) { return false; }
            };
            globalThis.__run = function (today) {
              const o = I20Analytics.runAll(__files, { today: today, source: "refuel log" });
              const s = (v) => (v == null ? null : JSON.stringify(v));
              return { data: s(o.data), fuel: s(o.fuel), performance: s(o.performance),
                       errors: o.errors.map((e) => e.page + ": " + e.message), warnings: o.warnings };
            };
            """)
        if let jsError { throw AnalyticsError.script(jsError) }
        guard let add = ctx.objectForKeyedSubscript("__add"), let runFn = ctx.objectForKeyedSubscript("__run") else {
            throw AnalyticsError.script("runner setup failed")
        }
        for p in paths {
            let text: String
            do { text = String(decoding: try book.read(p), as: UTF8.self) } catch {
                issues.append("\(p): couldn't be read, left out")
                continue
            }
            if add.call(withArguments: [p, text])?.toBool() != true, p.hasPrefix("raw/") {
                issues.append("\(p): not valid JSON, left out")  // log/ entries are reported by skippedEntries
            }
        }
        try Task.checkCancellation()

        // 3. Run.
        let out = runFn.call(withArguments: [today])
        if let jsError { throw AnalyticsError.script(jsError) }
        func string(_ key: String) -> String? {
            guard let v = out?.objectForKeyedSubscript(key), !v.isNull, !v.isUndefined else { return nil }
            return v.toString()
        }
        let errors = (out?.objectForKeyedSubscript("errors")?.toArray() as? [String]) ?? []
        issues += errors
        issues += AnalyticsRunner.newWarnings((out?.objectForKeyedSubscript("warnings")?.toArray() as? [String]) ?? [], besides: issues)
        self.issues = issues

        // Publish only a complete successful revision. A missing fuel output with no error means
        // there are no usable fills; it intentionally has no fuel.json in the new generation.
        guard errors.isEmpty, let data = string("data").map({ Data($0.utf8) }),
              let performance = string("performance").map({ Data($0.utf8) }) else {
            throw AnalyticsError.failed(errors.isEmpty ? ["no output"] : errors)
        }
        let fuel = string("fuel").map { Data($0.utf8) }
        try Task.checkCancellation()
        try beforePublication?()
        // Check after JS evaluation, against the pre-read snapshot rather than stamping whatever is
        // on disk now. A concurrent editor must not make old results appear current.
        let final = try inputSnapshot(book)
        guard final.signature == analysed.signature,
              let currentScript = try? Data(contentsOf: script), Self.digest(currentScript) == scriptDigest else {
            throw AnalyticsError.sourceChanged
        }
        do {
            try store.publish(data: data, fuel: fuel, performance: performance,
                archiveID: AnalyticsGeneration.archiveID(for: book.root), inputs: analysedInputs)
        } catch is CancellationError { throw CancellationError() }
        catch { throw AnalyticsError.saveFailed("local cache write failed") }

        Self.log.info("analytics: \(paths.count) files in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s, \(issues.count) issues")
        return (data, fuel, performance)
    }

    private struct InputSnapshot {
        let paths: [String]
        let signature: String
        let hasPlaceholders: Bool
    }

    private struct FileMetadata: Encodable {
        let path: String
        let availability: String
        let size: UInt64
        let modified: String
    }

    /// Runs only on this worker's executor. Photos and collection sidecars are not analytical inputs.
    /// Placeholder metadata is included so hydration or newly arriving cloud files invalidate the cache.
    private func inputSnapshot(_ book: Book) throws -> InputSnapshot {
        let paths = try (book.allFiles(under: "raw") + book.allFiles(under: "log"))
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".meta.json") }.sorted()
        var metadata: [FileMetadata] = []
        var hasPlaceholders = false
        let fm = FileManager.default
        for path in paths {
            try Task.checkCancellation()
            let file = try book.checkedURL(path)
            let placeholder = file.deletingLastPathComponent().appending(path: "." + file.lastPathComponent + ".icloud")
            var found = false
            for (url, availability) in [(file, "local"), (placeholder, "placeholder")] {
                guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { continue }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber,
                      let modified = attributes[.modificationDate] as? Date else { throw AnalyticsError.sourceChanged }
                found = true
                if availability == "placeholder" { hasPlaceholders = true }
                metadata.append(FileMetadata(path: path, availability: availability, size: size.uint64Value,
                    modified: String(modified.timeIntervalSinceReferenceDate.bitPattern, radix: 16)))
                // Match Book.read/ensureDownloaded: a materialized file wins over a shadow marker.
                // Cloud providers can briefly retain both; that marker must not force a rebuild loop.
                if availability == "local" { break }
            }
            guard found else { throw AnalyticsError.sourceChanged }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return InputSnapshot(paths: paths, signature: Self.digest(try encoder.encode(metadata)), hasPlaceholders: hasPlaceholders)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}
