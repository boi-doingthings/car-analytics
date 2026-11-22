import Foundation
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

    var errorDescription: String? {
        switch self {
        case .bundleMissing: "analytics.js is missing from the app"
        case .script(let m): "Analytics script error: \(m)"
        case .failed(let ms): "Analysis failed: " + ms.joined(separator: "; ")
        case .stillDownloading(let n): "\(n) file\(n == 1 ? "" : "s") still downloading from iCloud \u{2014} sync again shortly."
        case .saveFailed(let m): "Couldn't save the dashboard on this iPhone (\(m))."
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

    private static let log = Logger(subsystem: "com.i20logbook.app", category: "analytics")

    let derivedDir: URL
    let script: URL?
    /// How long to wait for one iCloud placeholder to download.
    var downloadTimeout: TimeInterval = AnalyticsRunner.defaultDownloadTimeout
    /// Problems of the last run (reset at its start): analytics page errors, raw files that couldn't be read or
    /// parsed, log entries skipped (newer schema / unreadable); or, when it threw `.stillDownloading`, the
    /// files still waiting for iCloud.
    private(set) var issues: [String] = []

    init(derivedDir: URL = AnalyticsRunner.defaultDerivedDir,
         script: URL? = Bundle.main.url(forResource: "analytics", withExtension: "js")) {
        self.derivedDir = derivedDir
        self.script = script
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
        guard let script, let source = try? String(contentsOf: script, encoding: .utf8) else {
            throw AnalyticsError.bundleMissing
        }
        self.issues = []
        var issues: [String] = []
        let started = Date()

        // 1. Every raw/** and log/** JSON except *.meta.json, downloaded if it is an iCloud placeholder.
        let paths = try (book.allFiles(under: "raw") + book.allFiles(under: "log"))
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".meta.json") }
        let timeout = downloadTimeout
        let missing = await withTaskGroup(of: String?.self) { group in
            for p in paths {
                group.addTask {
                    do { try await book.ensureDownloaded(p, timeout: timeout); return nil }
                    catch { return p }
                }
            }
            var out = Set<String>()
            for await p in group { if let p { out.insert(p) } }
            return out
        }
        try Task.checkCancellation()
        // A partial archive would overwrite good numbers with wrong ones: keep the last outputs instead.
        if !missing.isEmpty {
            self.issues = missing.sorted().map { "\($0): still downloading from iCloud" }
            throw AnalyticsError.stillDownloading(missing.count)
        }

        // Log entries Swift can't read (newer schema, bad shape) are listed; the JS skips newer schemas too.
        issues += skippedEntries(book)

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
        issues += Self.newWarnings((out?.objectForKeyedSubscript("warnings")?.toArray() as? [String]) ?? [], besides: issues)
        self.issues = issues

        // 4. Write what was built; a missing fuel output (no usable refuels) removes the stale file.
        let data = string("data").map { Data($0.utf8) }
        let fuel = string("fuel").map { Data($0.utf8) }
        let performance = string("performance").map { Data($0.utf8) }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: derivedDir, withIntermediateDirectories: true)
            if let data { try data.write(to: derivedDir.appending(path: "data.json"), options: .atomic) }
            if let performance { try performance.write(to: derivedDir.appending(path: "performance.json"), options: .atomic) }
            let fuelURL = derivedDir.appending(path: "fuel.json")
            if let fuel { try fuel.write(to: fuelURL, options: .atomic) }
            else if fm.fileExists(atPath: fuelURL.path) { try fm.removeItem(at: fuelURL) }
        } catch {
            throw AnalyticsError.saveFailed(error.localizedDescription)
        }

        Self.log.info("analytics: \(paths.count) files in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s, \(issues.count) issues")
        guard let data, let performance else {
            throw AnalyticsError.failed(errors.isEmpty ? ["no output"] : errors)
        }
        return (data, fuel, performance)
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
    private func skippedEntries(_ book: Book) -> [String] {
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
