import XCTest
@testable import I20Core

final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded { let method: String; let url: String; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var recorded: [Recorded] = []
    /// Returns (status, headers, body) or nil to simulate a timeout.
    nonisolated(unsafe) static var handler: ((Recorded) -> (Int, [String: String], Data)?)?
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: 4096); if n <= 0 { break }; body.append(buf, count: n) }
        }
        let rec = Recorded(method: request.httpMethod ?? "", url: request.url!.absoluteString,
                           headers: request.allHTTPHeaderFields ?? [:], body: body)
        StubProtocol.lock.lock()
        StubProtocol.recorded.append(rec)
        let h = StubProtocol.handler
        StubProtocol.lock.unlock()
        guard let (status, headers, data) = h?(rec) else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class BluelinkTests: XCTestCase {
    var signinCalls = 0

    override func setUp() {
        StubProtocol.recorded = []
        signinCalls = 0
    }

    private func makeClient() -> BluelinkClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        cfg.httpCookieStorage = HTTPCookieStorage()
        cfg.httpCookieAcceptPolicy = .always
        return BluelinkClient(config: .testFixture, session: URLSession(configuration: cfg), retryDelay: 0)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    /// signinBehaviour(n) for the n-th signin call (1-based): nil = timeout.
    private func install(signin: @escaping (Int) -> (Int, [String: String], Data)?) {
        StubProtocol.handler = { [self] r in
            if r.url.hasSuffix("notifications/register") {
                return (200, [:], json(#"{"retCode":"S","resMsg":{"deviceId":"dev1"}}"#))
            } else if r.url.contains("oauth2/authorize") {
                return (200, ["Set-Cookie": "account=abc; Path=/"], json("{}"))
            } else if r.url.hasSuffix("user/signin") {
                signinCalls += 1
                return signin(signinCalls)
            } else if r.url.hasSuffix("oauth2/token") {
                return (200, [:], json(#"{"token_type":"Bearer","access_token":"abc","refresh_token":"r"}"#))
            } else if r.url.hasSuffix("spa/vehicles") {
                return (200, [:], json(#"{"retCode":"S","resMsg":{"vehicles":[{"vehicleId":"v1","ccuCCS2ProtocolSupport":2},{"vehicleId":"v2"}]}}"#))
            }
            return (404, [:], json("{}"))
        }
    }

    private let okSignin: (Int) -> (Int, [String: String], Data)? = { _ in
        (200, [:], Data(#"{"redirectUrl":"https://x/redirect?code=CODE123&state=test"}"#.utf8))
    }

    func test_missingConfigurationFailsLocallyWithoutMakingRequests() async {
        let missingFields: [(inout BluelinkConfig) -> Void] = [
            { $0.ccspServiceId = "" }, { $0.appId = "" },
            { $0.cfbBase64 = "" }, { $0.basicAuthorization = "" },
        ]
        for removeField in missingFields {
            var configuration = BluelinkConfig.testFixture
            removeField(&configuration)
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [StubProtocol.self]
            let client = BluelinkClient(config: configuration, session: URLSession(configuration: session), retryDelay: 0)
            do {
                try await client.login(username: "test@example.invalid", password: "invented")
                XCTFail("Expected a local configuration failure")
            } catch {
                XCTAssertEqual(error as? BluelinkError, .configurationMissing)
            }
            XCTAssertTrue(StubProtocol.recorded.isEmpty, "Incomplete local configuration must never send a request")
        }
    }

    func test_stampMatchesSyntheticXorFixture() {
        XCTAssertEqual(makeClient().stamp(at: 1700000000),
                       "dGVzdC1hcHA6MTcwMDAwMDAwMA==")
    }

    func test_loginSequenceAndHeaders() async throws {
        install(signin: okSignin)
        let c = makeClient()
        try await c.login(username: "u@x.com", password: "pw")
        let v = try await c.vehicles()
        XCTAssertEqual(v.list, [Vehicle(id: "v1", ccs2: 2), Vehicle(id: "v2", ccs2: 0)])
        XCTAssertFalse(v.raw.isEmpty)

        let r = StubProtocol.recorded
        XCTAssertEqual(r.count, 5)
        XCTAssertTrue(r[0].url.hasSuffix("/api/v1/spa/notifications/register"))
        XCTAssertEqual(r[0].method, "POST")
        let reg = try JSONSerialization.jsonObject(with: r[0].body) as! [String: String]
        XCTAssertEqual(reg["pushType"], "GCM")
        XCTAssertEqual(reg["pushRegId"]?.count, 64)
        XCTAssertEqual(r[0].headers["Stamp"]?.isEmpty, false)
        XCTAssertTrue(r[1].url.contains("/api/v1/user/oauth2/authorize?response_type=code&state=test&client_id=test-service&redirect_uri=https://example.invalid/api/v1/user/oauth2/redirect"))
        XCTAssertTrue(r[2].url.hasSuffix("/api/v1/user/signin"))
        XCTAssertEqual(r[2].headers["Cookie"], "account=abc", "authorize cookie sent explicitly on signin")
        XCTAssertEqual(r[0].headers["ccsp-service-id"], "test-service")
        XCTAssertEqual(r[0].headers["ccsp-application-id"], "test-app")
        XCTAssertEqual(r[0].headers["User-Agent"], "test-agent")
        XCTAssertEqual(r[3].headers["User-Agent"], "test-agent")
        XCTAssertEqual(r[3].headers["Stamp"], r[0].headers["Stamp"])
        let body = try JSONSerialization.jsonObject(with: r[2].body) as! [String: String]
        XCTAssertEqual(body, ["email": "u@x.com", "password": "pw"])
        XCTAssertTrue(r[3].url.hasSuffix("/api/v1/user/oauth2/token"))
        let form = String(decoding: r[3].body, as: UTF8.self)
        XCTAssertTrue(form.hasPrefix("grant_type=authorization_code&redirect_uri=https%3A%2F%2Fexample.invalid%3A8080%2Fapi%2Fv1%2Fuser%2Foauth2%2Fredirect&code=CODE123"))
        XCTAssertTrue(r[3].headers["Authorization"]!.hasPrefix("Basic "))
        XCTAssertTrue(r[4].url.hasSuffix("/api/v1/spa/vehicles"))
        XCTAssertEqual(r[4].headers["Authorization"], "Bearer abc")
        XCTAssertEqual(r[4].headers["ccsp-device-id"], "dev1")
        XCTAssertEqual(r[4].headers["ccsp-service-id"], "test-service")
        XCTAssertEqual(r[4].headers["ccsp-application-id"], "test-app")
        XCTAssertEqual(r[4].headers["User-Agent"], "test-agent")
    }

    func test_getBeforeLoginFails() async {
        install(signin: okSignin)
        do { _ = try await makeClient().get("vehicles"); XCTFail() }
        catch { XCTAssertEqual(error as? BluelinkError, .loginFailed) }
    }

    func test_getReturnsRawBodyOnHttpErrorAndPostSendsJSON() async throws {
        install(signin: okSignin)
        let c = makeClient()
        try await c.login(username: "u", password: "p")
        let d = try await c.get("nothing")  // stub returns 404 {}
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "{}")
        _ = try await c.post("nothing", json: ["a": 1])
        let last = StubProtocol.recorded.last!
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.headers["Content-Type"], "application/json")
        XCTAssertEqual(String(decoding: last.body, as: UTF8.self), #"{"a":1}"#)
    }

    func test_loginRetriesOnceOnTimeout() async throws {
        install(signin: { [okSignin] n in n == 1 ? nil : okSignin(n) })
        let c = makeClient()
        try await c.login(username: "u", password: "p")
        XCTAssertEqual(signinCalls, 2)

        signinCalls = 0
        install(signin: { _ in nil })
        do { try await makeClient().login(username: "u", password: "p"); XCTFail("expected timeout") }
        catch { XCTAssertEqual(error as? BluelinkError, .timeout) }
        XCTAssertEqual(signinCalls, 2)
    }

    func test_signinWithoutRedirectFailsLogin() async {
        install(signin: { _ in (200, [:], Data(#"{"retCode":"F"}"#.utf8)) })
        do { try await makeClient().login(username: "u", password: "p"); XCTFail() }
        catch { XCTAssertEqual(error as? BluelinkError, .loginFailed) }
        XCTAssertEqual(signinCalls, 1)
    }

    func test_cancellationSurfacesAsCancellationError() async {
        StubProtocol.handler = { _ in nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CancelProtocol.self]
        let c = BluelinkClient(config: .testFixture, session: URLSession(configuration: cfg), retryDelay: 0)
        do { try await c.login(username: "u", password: "p"); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
}

final class CancelProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    override func stopLoading() {}
}
