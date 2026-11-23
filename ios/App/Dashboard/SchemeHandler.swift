import Foundation
import UniformTypeIdentifiers
import WebKit
import I20Core

/// Serves the dashboard at `i20://app/`:
/// - pages, styles, scripts and `vendor/**` from the bundled `web/` folder;
/// - `data.json`, `fuel.json`, `performance.json` only from `derived/` (never from the bundle);
/// - `GET /api/sync` → `{running, step, error, last_sync, issues}`, `POST /api/sync` starts a sync and
///   returns the same, matching web/common.js's protocol with serve.py.
@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "i20"
    static let derivedNames: Set<String> = ["data.json", "fuel.json", "performance.json"]
    private static let webExtensions: Set<String> = ["html", "css", "js"]

    private let webRoot: URL?
    private let sync: SyncCoordinator
    /// A page and all of its data requests see one revision, even while a sync publishes another.
    private var pinnedDerivedDir: URL?

    init(sync: SyncCoordinator, webRoot: URL? = Bundle.main.url(forResource: "web", withExtension: nil)) {
        self.sync = sync
        self.webRoot = webRoot
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let path = Self.requestPath(url) else { return fail(task, 404) }
        if path == "api/sync" {
            if task.request.httpMethod == "POST" {
                if !sync.archiveAllowsChanges || (Credentials.load() == nil && !DebugHarness.active) {
                    sync.rebuild()
                } else {
                    sync.syncNow()
                }
            }
            return respond(task, url: url, status: 200, type: "application/json", body: statusJSON())
        }
        if path.hasSuffix(".html") || path.isEmpty { pinnedDerivedDir = sync.derivedDir }
        guard let file = resolve(url: url) else { return fail(task, 404) }
        guard let body = try? Data(contentsOf: file) else { return fail(task, 404) }
        respond(task, url: url, status: 200, type: Self.mimeType(file.pathExtension), body: body)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Every response is sent synchronously in start(); nothing to cancel.
    }

    /// The decoded path (no leading slash) of an `i20://app/...` URL; nil for any other scheme or host.
    /// `URL.path` percent-decodes, so `%2e%2e` and `%2F` reach `resolve` as `..` and `/` and are checked there.
    static func requestPath(_ url: URL) -> String? {
        guard url.scheme == scheme, url.host == "app" else { return nil }
        let p = url.path
        return p.hasPrefix("/") ? String(p.dropFirst()) : p
    }

    /// The file for a full request URL (scheme/host checked, then `resolve`).
    func resolve(url: URL) -> URL? {
        guard let path = Self.requestPath(url) else { return nil }
        return resolve(path.isEmpty ? "index.html" : path)
    }

    /// Maps a request path to a file, or nil when it isn't one the dashboard may load.
    func resolve(_ path: String) -> URL? {
        let comps = path.split(separator: "/").map(String.init)
        guard !comps.isEmpty, !comps.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }) else { return nil }
        if comps.count == 1, Self.derivedNames.contains(comps[0]) {
            return (pinnedDerivedDir ?? sync.derivedDir).appending(path: comps[0])
        }
        guard let webRoot else { return nil }
        let isVendor = comps.count > 1 && comps[0] == "vendor"
        guard isVendor || (comps.count == 1 && Self.webExtensions.contains((comps[0] as NSString).pathExtension)) else {
            return nil
        }
        return webRoot.appending(path: comps.joined(separator: "/"))
    }

    func statusJSON() -> Data {
        let s = sync.state
        let obj: [String: Any] = [
            "running": s.running,
            "step": s.step ?? NSNull(),
            "error": s.error ?? NSNull(),
            "last_sync": s.lastSync.map { istTimestamp($0) } ?? NSNull(),
            "issues": s.issues.count,
            "last_analysis": s.lastAnalysis.map { istTimestamp($0) } ?? NSNull(),
            "read_only": !sync.archiveAllowsChanges,
            "analysis_generation": sync.hasCurrentArchiveSnapshot ? sync.derivedDir.lastPathComponent : NSNull(),
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html"
        case "css": "text/css"
        case "js": "text/javascript"
        case "json": "application/json"
        default: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, body: Data) {
        let headers = ["Content-Type": type.hasPrefix("text/") || type.hasSuffix("json") ? type + "; charset=utf-8" : type,
                       "Content-Length": String(body.count), "Cache-Control": "no-store"]
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, _ status: Int) {
        let url = task.request.url ?? URL(string: "i20://app/")!
        respond(task, url: url, status: status, type: "text/plain", body: Data("\(status)".utf8))
    }
}
