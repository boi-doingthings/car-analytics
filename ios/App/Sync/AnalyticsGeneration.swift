import Foundation
import CryptoKit

/// A complete cache revision. Only the small manifest is replaced when a new revision is ready.
/// The portable archive is never modified by this store.
struct AnalyticsGeneration {
    struct Manifest: Codable {
        let schema: Int
        let generation: String
        let publishedAt: Date
        let archiveID: String?
    }

    /// Local-only identity; the actual selected folder path is never embedded in derived artifacts.
    static func archiveID(for root: URL) -> String {
        SHA256.hash(data: Data(root.standardizedFileURL.resolvingSymlinksInPath().absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    let root: URL
    private var manifestURL: URL { root.appending(path: "current.json") }

    var manifest: Manifest? {
        guard let data = try? Data(contentsOf: manifestURL),
              let value = try? JSONDecoder().decode(Manifest.self, from: data),
              value.schema == 1, UUID(uuidString: value.generation) != nil else { return nil }
        return value
    }

    /// Legacy lookup for migration/tests; SyncCoordinator rejects unverifiable caches for a selected archive.
    var directory: URL {
        guard let manifest else { return root }
        return root.appending(path: "generations", directoryHint: .isDirectory)
            .appending(path: manifest.generation, directoryHint: .isDirectory)
    }

    /// Files become visible together, after every write succeeds. Previously published generations
    /// remain readable by a screen that captured its directory before a new generation was published.
    func publish(data: Data, fuel: Data?, performance: Data, archiveID: String? = nil, now: Date = Date()) throws {
        let fm = FileManager.default
        let id = UUID().uuidString.lowercased()
        let generations = root.appending(path: "generations", directoryHint: .isDirectory)
        let destination = generations.appending(path: id, directoryHint: .isDirectory)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: destination) } }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.write(to: destination.appending(path: "data.json"), options: .atomic)
        try performance.write(to: destination.appending(path: "performance.json"), options: .atomic)
        if let fuel { try fuel.write(to: destination.appending(path: "fuel.json"), options: .atomic) }
        try Task.checkCancellation()
        let manifest = Manifest(schema: 1, generation: id, publishedAt: now, archiveID: archiveID)
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        committed = true
        prune(now: now)
    }
    /// Keep the current and two previous complete revisions, plus a 24-hour grace period for
    /// readers that pinned an older directory. Cleanup is best effort and cannot fail publication.
    /// A reader left open beyond the grace period may need to reload its page.
    func prune(now: Date = Date(), gracePeriod: TimeInterval = 24 * 3600) {
        guard let current = manifest?.generation else { return }
        let fm = FileManager.default
        let generations = root.appending(path: "generations", directoryHint: .isDirectory)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let contents = try? fm.contentsOfDirectory(at: generations,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        let revisions: [(url: URL, modified: Date, complete: Bool)] = contents.compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate else { return nil }
            let complete = fm.fileExists(atPath: url.appending(path: "data.json").path)
                && fm.fileExists(atPath: url.appending(path: "performance.json").path)
            return (url, modified, complete)
        }.sorted { $0.modified > $1.modified }
        let previous = revisions.filter { $0.complete && $0.url.lastPathComponent != current }.prefix(2)
        let retained = Set(previous.map { $0.url.lastPathComponent }).union([current])
        for revision in revisions where !retained.contains(revision.url.lastPathComponent)
            && now.timeIntervalSince(revision.modified) > gracePeriod {
            try? fm.removeItem(at: revision.url)
        }
    }

}
