import XCTest
import WebKit
import I20Core
@testable import I20Logbook

@MainActor
final class SchemeHandlerTests: XCTestCase {
    let derived = URL(fileURLWithPath: "/tmp/derived-test")
    let web = URL(fileURLWithPath: "/tmp/web-test")

    func handler() -> SchemeHandler {
        let sync = SyncCoordinator(book: { nil }, runner: AnalyticsRunner(derivedDir: derived))
        return SchemeHandler(sync: sync, webRoot: web)
    }

    func test_dataFilesComeOnlyFromDerived() {
        let h = handler()
        for name in ["data.json", "fuel.json", "performance.json"] {
            XCTAssertEqual(h.resolve(name), derived.appending(path: name))
        }
        XCTAssertNil(h.resolve("sub/data.json"))
        XCTAssertNil(h.resolve("other.json"))
    }

    func test_webFilesFromBundleAndNothingElse() {
        let h = handler()
        XCTAssertEqual(h.resolve("index.html"), web.appending(path: "index.html"))
        XCTAssertEqual(h.resolve("common.js"), web.appending(path: "common.js"))
        XCTAssertEqual(h.resolve("vendor/leaflet.css"), web.appending(path: "vendor/leaflet.css"))
        XCTAssertNil(h.resolve("../secrets.html"))
        XCTAssertNil(h.resolve("vendor/../../x.js"))
        XCTAssertNil(h.resolve(".hidden.js"))
        XCTAssertNil(h.resolve("readme.md"))
    }

    func test_encodedTraversalAndOtherHostsRefused() throws {
        let h = handler()
        let u = { (s: String) in try XCTUnwrap(URL(string: s)) }
        XCTAssertEqual(h.resolve(url: try u("i20://app/index.html")), web.appending(path: "index.html"))
        XCTAssertEqual(h.resolve(url: try u("i20://app/")), web.appending(path: "index.html"))
        XCTAssertEqual(h.resolve(url: try u("i20://app/data.json")), derived.appending(path: "data.json"))
        XCTAssertNil(h.resolve(url: try u("i20://app/%2e%2e/secrets.js")))
        XCTAssertNil(h.resolve(url: try u("i20://app/%2E%2E%2Fsecrets.js")))
        XCTAssertNil(h.resolve(url: try u("i20://app/vendor%2F..%2F..%2Fx.js")))
        XCTAssertNil(h.resolve(url: try u("i20://app/vendor/%2e%2e/%2e%2e/x.js")))
        XCTAssertNil(h.resolve(url: try u("i20://other/index.html")))
        XCTAssertNil(h.resolve(url: try u("i20:///index.html")))
        XCTAssertNil(h.resolve(url: try u("https://app/index.html")))
    }

    func test_statusJSONMatchesServeProtocol() throws {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: handler().statusJSON()) as? [String: Any])
        XCTAssertEqual(obj["running"] as? Bool, false)
        XCTAssertTrue(obj["step"] is NSNull)
        XCTAssertTrue(obj["error"] is NSNull)
        XCTAssertTrue(obj["last_sync"] is NSNull)
        XCTAssertEqual(obj["issues"] as? Int, 0)
        XCTAssertEqual(obj["read_only"] as? Bool, true)
        XCTAssertTrue(obj["last_analysis"] is NSNull)
        XCTAssertTrue(obj["analysis_generation"] is NSNull)
    }
    func test_webDashboardReloadsOnPublicationButNotRepeatedPassiveVisits() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dashboard-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        let root = folder.appending(path: "i20_book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: root)
        let book = Book(root: root, writeAuthorization: BookWriteAuthorization(allowed: false))
        let sync = SyncCoordinator(book: { book }, runner: AnalyticsRunner(derivedDir: folder.appending(path: "derived")), automaticCollection: { false })
        let coordinator = DashboardWebView.Coordinator(sync: sync)
        let web = ReloadCountingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        coordinator.web = web
        let published = expectation(description: "one web reload for the first completed generation")
        web.onReload = { published.fulfill() }
        sync.rebuild()
        await sync.task?.value
        await fulfillment(of: [published], timeout: 5)
        XCTAssertEqual(web.reloadCount, 1)
        web.onReload = nil
        let first = sync.derivedDir
        for _ in 0..<5 {
            sync.syncIfStale()
            await sync.task?.value
        }
        XCTAssertEqual(sync.derivedDir, first)
        XCTAssertEqual(sync.finishedRuns, 1)
        XCTAssertEqual(web.reloadCount, 1, "passive visits must not publish or reload an unchanged page")
        withExtendedLifetime(coordinator) {}
    }

    func test_realWebPageStaysIdleUntilAnExplicitReadonlyRefresh() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "web-idle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "book", withExtension: nil))
        let root = folder.appending(path: "i20_book")
        try FileManager.default.copyItem(at: source, to: root)
        let book = Book(root: root, writeAuthorization: BookWriteAuthorization(allowed: false))
        let sync = SyncCoordinator(book: { book }, runner: AnalyticsRunner(derivedDir: folder.appending(path: "derived")), automaticCollection: { false })
        sync.rebuild()
        await sync.task?.value
        let first = sync.derivedDir
        let webRoot = folder.appending(path: "web")
        try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "web", withExtension: nil))
        try FileManager.default.copyItem(at: bundled.appending(path: "common.js"), to: webRoot.appending(path: "common.js"))
        let html = #"<html><body><span id="sync-label"></span><button id="sync-btn">Sync now</button><script src="common.js"></script><script>LB.initSync().then(()=>window.webkit.messageHandlers.ready.postMessage('ready'));</script></body></html>"#
        try html.write(to: webRoot.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let handler = ObservedSchemeHandler(delegate: SchemeHandler(sync: sync, webRoot: webRoot))
        let ready = ReadyMessageHandler()
        let loaded = expectation(description: "actual native web sync initialized")
        let refreshed = expectation(description: "explicit refresh reloads once")
        ready.onReady = { count in
            if count == 1 { loaded.fulfill() }
            else if count == 2 { refreshed.fulfill() }
            else { XCTFail("unchanged native page reloaded repeatedly") }
        }
        let unexpected = expectation(description: "page-load never starts archive work")
        unexpected.isInverted = true
        handler.onPost = { _ in unexpected.fulfill() }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: SchemeHandler.scheme)
        config.userContentController.add(ready, name: "ready")
        defer { config.userContentController.removeScriptMessageHandler(forName: "ready") }
        let web = WKWebView(frame: .zero, configuration: config)
        web.load(URLRequest(url: try XCTUnwrap(URL(string: "i20://app/index.html"))))
        await fulfillment(of: [loaded], timeout: 20)
        await fulfillment(of: [unexpected], timeout: 2)
        XCTAssertEqual(sync.derivedDir, first)
        XCTAssertEqual(sync.finishedRuns, 1)
        let manual = expectation(description: "one explicit refresh POST")
        let duplicate = expectation(description: "terminal reload never starts another POST")
        duplicate.isInverted = true
        handler.onPost = { count in
            if count == 1 { manual.fulfill() }
            else { duplicate.fulfill() }
        }
        _ = try await web.evaluateJavaScript("document.querySelector('#sync-btn').click()")
        await fulfillment(of: [manual, refreshed], timeout: 20)
        await fulfillment(of: [duplicate], timeout: 2)
        XCTAssertEqual(handler.posts, 1)
        XCTAssertEqual(sync.finishedRuns, 2)
        XCTAssertNotEqual(sync.derivedDir, first)
        withExtendedLifetime((handler, ready, web)) {}
    }

}


@MainActor
private final class ReloadCountingWebView: WKWebView {
    private(set) var reloadCount = 0
    var onReload: (() -> Void)?
    override func reload() -> WKNavigation? {
        reloadCount += 1
        onReload?()
        return nil
    }
}


@MainActor
private final class ReadyMessageHandler: NSObject, WKScriptMessageHandler {
    private var count = 0
    var onReady: ((Int) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        count += 1
        onReady?(count)
    }
}

@MainActor
private final class ObservedSchemeHandler: NSObject, WKURLSchemeHandler {
    let delegate: SchemeHandler
    private(set) var posts = 0
    var onPost: ((Int) -> Void)?
    init(delegate: SchemeHandler) { self.delegate = delegate }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        if task.request.url?.path == "/api/sync", task.request.httpMethod == "POST" {
            posts += 1
            onPost?(posts)
        }
        delegate.webView(webView, start: task)
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { delegate.webView(webView, stop: task) }
}
