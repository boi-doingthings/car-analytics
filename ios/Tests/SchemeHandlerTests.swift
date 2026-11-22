import XCTest
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
    }
}
