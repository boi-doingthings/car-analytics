import Foundation

/// Constants for the Hyundai India Bluelink (CCSP) API; copied from
/// hyundai_kia_connect_api `KiaUvoApiIN.py` (Hyundai branch).
public struct BluelinkConfig: Sendable {
    public var baseURL: String
    public var ccspServiceId: String
    public var appId: String
    /// base64 of the stamp XOR key ("CFB").
    public var cfbBase64: String
    public var basicAuthorization: String
    public var pushType: String
    public var userAgent: String
    public var requestTimeout: TimeInterval

    public init(baseURL: String, ccspServiceId: String, appId: String, cfbBase64: String,
                basicAuthorization: String, pushType: String, userAgent: String,
                requestTimeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.ccspServiceId = ccspServiceId
        self.appId = appId
        self.cfbBase64 = cfbBase64
        self.basicAuthorization = basicAuthorization
        self.pushType = pushType
        self.userAgent = userAgent
        self.requestTimeout = requestTimeout
    }

    /// Local configuration only. The app reads a gitignored bundled plist; CLI smoke tests use env.
    public static var indiaHyundai: BluelinkConfig {
        let env = ProcessInfo.processInfo.environment
        let local = Bundle.main.url(forResource: "Bluelink.local", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        func value(_ key: String) -> String { env[key] ?? local[key] ?? "" }
        return BluelinkConfig(
            baseURL: "https://prd.in-ccapi.hyundai.connected-car.io:8080",
            ccspServiceId: value("BLUELINK_SERVICE_ID"),
            appId: value("BLUELINK_APP_ID"),
            cfbBase64: value("BLUELINK_STAMP_KEY"),
            basicAuthorization: value("BLUELINK_BASIC_AUTH"),
            pushType: "GCM", userAgent: "okhttp/3.12.0")
    }

    /// Invented protocol configuration for isolated tests. Never connects to a real vehicle.
    public static let testFixture = BluelinkConfig(
        baseURL: "https://example.invalid", ccspServiceId: "test-service",
        appId: "test-app", cfbBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        basicAuthorization: "Basic dGVzdDp0ZXN0", pushType: "GCM", userAgent: "test-agent")
}

public struct Vehicle: Sendable, Equatable {
    public let id: String
    public let ccs2: Int
    public init(id: String, ccs2: Int) { self.id = id; self.ccs2 = ccs2 }
}

public enum BluelinkError: Error, Equatable {
    case configurationMissing
    case loginFailed
    case timeout
    case badResponse(String)
}

/// Read-only Bluelink client. Concurrency: a `final class` whose only mutable
/// state (access token, device id) is guarded by an `NSLock`, so it is safely
/// `Sendable`. Cookies live in the supplied session's cookie storage, so pass a
/// session (ephemeral config) dedicated to one client.
///
/// `get`/`post` return the raw response body for ANY HTTP status (the collector
/// inspects `retCode`); only transport failures throw (`.timeout` for timeouts,
/// `.badResponse` otherwise). Credentials are never logged or stored beyond the
/// in-memory access token.
public final class BluelinkClient: @unchecked Sendable {
    private let config: BluelinkConfig
    private let session: URLSession
    private let lock = NSLock()
    private var accessToken: String?
    private var deviceId: String?
    private let retryDelay: TimeInterval

    /// `retryDelay`: pause before the single login retry after a timeout (collect.py waits
    /// 15 s because the server stalls); tests pass 0.
    public init(config: BluelinkConfig = .indiaHyundai, session: URLSession,
                retryDelay: TimeInterval = 15) {
        self.config = config
        self.session = session
        self.retryDelay = retryDelay
    }

    private var userAPI: String { config.baseURL + "/api/v1/user/" }
    private var spaAPI: String { config.baseURL + "/api/v1/spa/" }

    // MARK: Stamp

    public func stamp(at unix: Int) -> String {
        let cfb = [UInt8](Data(base64Encoded: config.cfbBase64) ?? Data())
        let raw = [UInt8]("\(config.appId):\(unix)".utf8)
        let out = zip(cfb, raw).map { $0 ^ $1 }  // zip truncates like Python
        return Data(out).base64EncodedString()
    }

    // MARK: Login

    /// Full login; retried once (from the start) if it times out.
    public func login(username: String, password: String) async throws {
        do {
            try await loginOnce(username: username, password: password)
        } catch BluelinkError.timeout {
            if retryDelay > 0 { try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000)) }
            try await loginOnce(username: username, password: password)
        }
    }

    private func loginOnce(username: String, password: String) async throws {
        guard !config.ccspServiceId.isEmpty, !config.appId.isEmpty,
              !config.cfbBase64.isEmpty, !config.basicAuthorization.isEmpty else {
            throw BluelinkError.configurationMissing
        }
        let stamp = stamp(at: Int(Date().timeIntervalSince1970))

        // 1. Register a device -> deviceId
        let regBody: [String: Any] = [
            "pushRegId": Self.randomHex64(),
            "pushType": config.pushType,
            "uuid": UUID().uuidString.lowercased(),
        ]
        let regData = try await send(
            url: spaAPI + "notifications/register", method: "POST",
            headers: [
                "ccsp-service-id": config.ccspServiceId,
                "ccsp-application-id": config.appId,
                "Stamp": stamp,
                "Content-Type": "application/json;charset=UTF-8",
                "User-Agent": config.userAgent,
            ],
            body: try JSONSerialization.data(withJSONObject: regBody, options: [.sortedKeys]))
        guard let reg = try? JSONSerialization.jsonObject(with: regData) as? [String: Any],
              let regMsg = reg["resMsg"] as? [String: Any],
              let devId = regMsg["deviceId"] as? String else {
            throw BluelinkError.badResponse("register: no deviceId")
        }

        // 2. Authorize (sets cookies in the session's cookie storage)
        let redirect = userAPI + "oauth2/redirect"
        let authURL = userAPI + "oauth2/authorize?response_type=code&state=test&client_id="
            + config.ccspServiceId + "&redirect_uri=" + redirect
        let (_, authResp) = try await sendRaw(url: authURL, method: "GET", headers: [:], body: nil)
        // Like Python (cookies from the authorize call passed explicitly to signin): collect
        // Set-Cookie from the response plus anything in the session's storage.
        var jar: [String: String] = [:]
        if let u = URL(string: authURL) {
            for c in session.configuration.httpCookieStorage?.cookies(for: u) ?? [] { jar[c.name] = c.value }
            if let fields = authResp?.allHeaderFields as? [String: String] {
                for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: u) { jar[c.name] = c.value }
            }
        }
        var signinHeaders = ["Content-Type": "application/json"]
        if !jar.isEmpty {
            signinHeaders["Cookie"] = jar.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }

        // 3. Sign in -> redirectUrl carrying the code
        let signinBody = try JSONSerialization.data(
            withJSONObject: ["email": username, "password": password], options: [.sortedKeys])
        let signinData = try await send(
            url: userAPI + "signin", method: "POST",
            headers: signinHeaders, body: signinBody)
        guard let signin = try? JSONSerialization.jsonObject(with: signinData) as? [String: Any],
              let redirectUrl = signin["redirectUrl"] as? String,
              let comps = URLComponents(string: redirectUrl),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw BluelinkError.loginFailed
        }

        // 4. Exchange the code for an access token (form body as in Python)
        let host = config.baseURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: ":8080", with: "")
        let form = "grant_type=authorization_code&redirect_uri=https%3A%2F%2F" + host
            + "%3A8080%2Fapi%2Fv1%2Fuser%2Foauth2%2Fredirect&code=" + code
        let tokData = try await send(
            url: userAPI + "oauth2/token", method: "POST",
            headers: [
                "Authorization": config.basicAuthorization,
                "Stamp": stamp,
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": config.userAgent,
            ],
            body: Data(form.utf8))
        guard let tok = try? JSONSerialization.jsonObject(with: tokData) as? [String: Any],
              let type = tok["token_type"] as? String,
              let access = tok["access_token"] as? String else {
            throw BluelinkError.badResponse("token: missing access_token")
        }

        lock.withLock {
            accessToken = type + " " + access
            deviceId = devId
        }
    }

    // MARK: Authenticated calls

    private func authHeaders(extra: [String: String]) throws -> [String: String] {
        let (token, dev) = lock.withLock { (accessToken, deviceId) }
        guard let token, let dev else { throw BluelinkError.loginFailed }
        var h = [
            "Authorization": token,
            "ccsp-service-id": config.ccspServiceId,
            "ccsp-application-id": config.appId,
            "ccsp-device-id": dev,
            "User-Agent": config.userAgent,
        ]
        for (k, v) in extra { h[k] = v }
        return h
    }

    /// GET `<base>/api/v1/spa/<path>`; returns raw bytes for any HTTP status.
    /// `extraHeaders` e.g. `Ccuccs2protocolsupport` for per-vehicle calls.
    public func get(_ path: String, extraHeaders: [String: String] = [:]) async throws -> Data {
        try await send(url: spaAPI + path, method: "GET",
                       headers: try authHeaders(extra: extraHeaders), body: nil)
    }

    public func post(_ path: String, json: [String: Any],
                     extraHeaders: [String: String] = [:]) async throws -> Data {
        var h = try authHeaders(extra: extraHeaders)
        h["Content-Type"] = "application/json"
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return try await send(url: spaAPI + path, method: "POST", headers: h, body: body)
    }

    public func vehicles() async throws -> (raw: Data, list: [Vehicle]) {
        let raw = try await get("vehicles")
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let msg = obj["resMsg"] as? [String: Any],
              let arr = msg["vehicles"] as? [[String: Any]] else {
            throw BluelinkError.badResponse("vehicles: unexpected body")
        }
        let list = arr.compactMap { e -> Vehicle? in
            guard let id = e["vehicleId"] as? String else { return nil }
            return Vehicle(id: id, ccs2: (e["ccuCCS2ProtocolSupport"] as? Int) ?? 0)
        }
        return (raw, list)
    }

    // MARK: Transport

    private func send(url: String, method: String, headers: [String: String],
                      body: Data?) async throws -> Data {
        try await sendRaw(url: url, method: method, headers: headers, body: body).0
    }

    private func sendRaw(url: String, method: String, headers: [String: String],
                         body: Data?) async throws -> (Data, HTTPURLResponse?) {
        guard let u = URL(string: url) else { throw BluelinkError.badResponse("bad url") }
        var req = URLRequest(url: u, timeoutInterval: config.requestTimeout)
        req.httpMethod = method
        // Host is managed by URLSession; Connection/Accept-Encoding are left to it too.
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        do {
            let (data, resp) = try await session.data(for: req)
            return (data, resp as? HTTPURLResponse)
        } catch let e as URLError where e.code == .timedOut {
            throw BluelinkError.timeout
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as BluelinkError {
            throw e
        } catch {
            throw BluelinkError.badResponse("transport: \((error as? URLError)?.code.rawValue ?? 0)")
        }
    }

    private static func randomHex64() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
