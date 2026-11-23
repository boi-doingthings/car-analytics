import Foundation

public enum BookError: Error, Equatable {
    /// The book folder is missing or not a directory (iCloud signed out, folder deleted, stale bookmark).
    case unreachable
    /// The selected archive has not been authorized for writes, or its authorization was revoked.
    case readOnly
    /// A relative path that is absolute or contains `..`.
    case outsideRoot(String)
    /// The file is an iCloud placeholder that has not been downloaded (or does not exist).
    case notDownloaded(String)
    /// iCloud refused to start the download (path, underlying error text); thrown when the wait times out.
    case downloadFailed(String, String)
}

/// Shared revocable permission for every writer holding a Book reference. Mutation is serialized
/// with revocation: once setAllowed(false) returns, a coordinated write cannot begin or continue.
public final class BookWriteAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Bool

    public init(allowed: Bool = true) { self.allowed = allowed }

    public var canWrite: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }

    public func setAllowed(_ allowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.allowed = allowed
    }

    fileprivate func withWritePermission<T>(_ mutation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard allowed else { throw BookError.readOnly }
        return try mutation()
    }

    fileprivate func requireWritePermission() throws {
        try withWritePermission { }
    }
}

/// The owner's `i20_book` folder. All paths are relative to `root` and validated to stay inside it.
///
/// `Book` holds an immutable `URL` and thread-safe write authorization and uses
/// `FileManager.default` / `NSFileCoordinator` per call, so it can be shared across actors. Methods are synchronous (blocking file I/O) except
/// `ensureDownloaded`; call them off the main actor for big trees.
public final class Book: Sendable {
    public let root: URL
    public let writeAuthorization: BookWriteAuthorization
    public var canWrite: Bool { writeAuthorization.canWrite }

    /// Core callers keep the original writable default. The app injects a read-only policy until
    /// the owner explicitly authorizes this particular archive.
    public init(root: URL, writeAuthorization: BookWriteAuthorization = BookWriteAuthorization()) {
        // Resolved once, so containment checks compare real paths (e.g. /var -> /private/var).
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.writeAuthorization = writeAuthorization
    }

    // MARK: paths

    /// The file URL for a relative path, validated to stay inside the real (symlink-resolved) root.
    /// Throws `.outsideRoot` for `..`, absolute paths, symlinks leading out of the book, and (unless
    /// `allowRoot`) for empty or `.`-only paths, which would address the root itself.
    public func checkedURL(_ rel: String, allowRoot: Bool = false) throws -> URL {
        if rel.hasPrefix("/") || rel.hasPrefix("~") || rel.contains("\0") { throw BookError.outsideRoot(rel) }
        let comps = rel.split(separator: "/", omittingEmptySubsequences: true)
        if comps.contains("..") { throw BookError.outsideRoot(rel) }
        if !allowRoot, comps.allSatisfy({ $0 == "." }) { throw BookError.outsideRoot(rel) }
        let target = comps.isEmpty ? root : root.appending(path: rel)
        // Resolve the deepest existing ancestor (lstat, so dangling links count) and require it inside root.
        let fm = FileManager.default
        var probe = target.standardizedFileURL
        while (try? fm.attributesOfItem(atPath: probe.path)) == nil, probe.path != root.path, probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let real = probe.resolvingSymlinksInPath().path
        if real != root.path, !real.hasPrefix(root.path + "/") { throw BookError.outsideRoot(rel) }
        return target
    }

    /// Non-throwing form of `checkedURL`; a path outside the root maps to a dead URL inside the root
    /// (`root/.outside-root`) so it can never address anything outside the book.
    public func url(_ rel: String) -> URL {
        (try? checkedURL(rel, allowRoot: true)) ?? root.appending(path: ".outside-root")
    }

    private func placeholderURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appending(path: "." + fileURL.lastPathComponent + ".icloud")
    }

    private func requireRoot() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw BookError.unreachable
        }
    }

    // MARK: queries

    /// True if the file exists, or exists as an iCloud placeholder (`.name.icloud`).
    public func exists(_ rel: String) -> Bool {
        guard let u = try? checkedURL(rel) else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: u.path) || fm.fileExists(atPath: placeholderURL(for: u).path)
    }

    /// Entry names in a directory (files and folders). `.x.icloud` placeholders are reported as `x`; other
    /// dot files are hidden. A missing directory lists as empty; a missing root throws `.unreachable`.
    public func list(_ dir: String) throws -> [String] {
        let d = try checkedURL(dir, allowRoot: true)
        try requireRoot()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return [] }
        var out = Set<String>()
        for n in names {
            if n.hasPrefix("."), n.hasSuffix(".icloud"), n.count > ".icloud".count + 1 {
                let real = String(n.dropFirst().dropLast(".icloud".count))
                if !real.hasPrefix(".") { out.insert(real) }  // placeholders of dot files stay hidden
            } else if !n.hasPrefix(".") {
                out.insert(n)
            }
        }
        return out.sorted()
    }

    /// Every file under `dir`, recursively, as paths relative to the root (placeholders under their real name).
    public func allFiles(under dir: String) throws -> [String] {
        try requireRoot()
        var out: [String] = []
        func walk(_ rel: String) throws {
            let prefix = rel.isEmpty ? "" : rel.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            for name in try list(rel) {
                let child = prefix + name
                var isDir: ObjCBool = false
                let childURL = root.appending(path: child)  // unresolved on purpose: lstat must see the link itself
                let attrs = try? FileManager.default.attributesOfItem(atPath: childURL.path)
                if attrs?[.type] as? FileAttributeType == .typeSymbolicLink { continue }  // never follow links
                if FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue {
                    try walk(child)
                } else {
                    out.append(child)
                }
            }
        }
        try walk(dir)
        return out.sorted()
    }

    // MARK: read / write

    /// Reads a file (coordinated). A not-yet-downloaded placeholder throws `.notDownloaded`; call
    /// `ensureDownloaded` first.
    public func read(_ rel: String) throws -> Data {
        let u = try checkedURL(rel)
        try requireRoot()
        let fm = FileManager.default
        if !fm.fileExists(atPath: u.path), fm.fileExists(atPath: placeholderURL(for: u).path) {
            throw BookError.notDownloaded(rel)
        }
        var result: Result<Data, Error>?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: u, options: [], error: &coordError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordError { throw coordError }
        return try result!.get()
    }

    /// Atomically writes a file (coordinated), creating parent folders. Throws `.unreachable` if the book
    /// folder itself is missing; never creates the root.
    public func writeAtomic(_ rel: String, _ data: Data) throws {
        try writeAuthorization.requireWritePermission()
        let u = try checkedURL(rel)
        try requireRoot()
        var result: Result<Void, Error>?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: u, options: .forReplacing, error: &coordError) { url in
            result = Result {
                try writeAuthorization.withWritePermission {
                    // Authorization can change while NSFileCoordinator is waiting on another writer.
                    try requireRoot()
                    _ = try checkedURL(rel)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                }
            }
        }
        if let coordError { throw coordError }
        try result!.get()
    }

    /// Deletes a file (or its placeholder if it was never downloaded), coordinated.
    public func delete(_ rel: String) throws {
        try writeAuthorization.requireWritePermission()
        let u = try checkedURL(rel)
        try requireRoot()
        let fm = FileManager.default
        let target = fm.fileExists(atPath: u.path) ? u : placeholderURL(for: u)
        var result: Result<Void, Error>?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forDeleting, error: &coordError) { url in
            result = Result {
                try writeAuthorization.withWritePermission {
                    try requireRoot()
                    _ = try checkedURL(rel)
                    try fm.removeItem(at: url)
                }
            }
        }
        if let coordError { throw coordError }
        try result!.get()
    }

    /// Makes sure a file is really on disk: if only a placeholder exists, asks iCloud to download it and polls
    /// (every 100 ms) until the placeholder is gone. Returns immediately if the file is already present.
    /// Throws `.notDownloaded` on timeout or when neither the file nor a placeholder exists.
    public func ensureDownloaded(_ rel: String, timeout: TimeInterval) async throws {
        let u = try checkedURL(rel)
        try requireRoot()
        let fm = FileManager.default
        if fm.fileExists(atPath: u.path) { return }
        guard fm.fileExists(atPath: placeholderURL(for: u).path) else { throw BookError.notDownloaded(rel) }
        // A failure here is kept and reported only if the wait times out (outside iCloud it always fails).
        var startError: Error?
        do { try fm.startDownloadingUbiquitousItem(at: u) } catch { startError = error }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fm.fileExists(atPath: u.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if fm.fileExists(atPath: u.path) { return }
        if let startError { throw BookError.downloadFailed(rel, startError.localizedDescription) }
        throw BookError.notDownloaded(rel)
    }
}
