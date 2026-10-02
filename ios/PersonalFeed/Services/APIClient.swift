import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case server(Int, String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your session ended. Please sign in again."
        case .server(_, let message): message
        case .notConfigured: "API_BASE_URL isn't set in the app's build settings."
        }
    }
}

struct SignInResponse: Decodable {
    struct User: Decodable { let id: String }
    let token: String
    let created: Bool
    let user: User
    let settings: UserSettings
}

private struct MeResponse: Decodable { let settings: UserSettings }
private struct SettingsResponse: Decodable { let settings: UserSettings }
private struct ErrorBody: Decodable { let error: String }

/// Talks to the Cloudflare Worker in server/. The base URL comes from Info.plist (API_BASE_URL).
struct APIClient: Sendable {
    let baseURL: URL

    static func fromBundle() -> APIClient? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
              let url = URL(string: s), url.scheme?.hasPrefix("http") == true
        else { return nil }
        return APIClient(baseURL: url)
    }

    // MARK: Feed

    enum FeedResult {
        case notModified
        case fresh(SharedFeed, data: Data, etag: String?)
    }

    func feed(etag: String?) async throws -> FeedResult {
        var request = URLRequest(url: baseURL.appending(path: "v1/feed"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304 { return .notModified }
        try check(data, http)
        let feed = try JSONDecoder.api.decode(SharedFeed.self, from: data)
        return .fresh(feed, data: data, etag: http?.value(forHTTPHeaderField: "ETag"))
    }

    // MARK: Account

    func signInWithApple(identityToken: String) async throws -> SignInResponse {
        try await send("POST", "v1/auth/apple",
                       body: ["identityToken": identityToken, "timezone": TimeZone.current.identifier])
    }

    func settings(token: String) async throws -> UserSettings {
        let me: MeResponse = try await send("GET", "v1/me", token: token)
        return me.settings
    }

    func save(settings: UserSettings, token: String) async throws -> UserSettings {
        let r: SettingsResponse = try await send("PUT", "v1/me/settings", token: token, encodable: settings)
        return r.settings
    }

    func registerDevice(_ deviceToken: String, sandbox: Bool, token: String) async throws {
        let _: [String: Bool] = try await send("POST", "v1/me/devices", token: token,
                                               body: ["token": deviceToken, "environment": sandbox ? "sandbox" : "production"])
    }

    func removeDevice(_ deviceToken: String, token: String) async throws {
        let _: [String: Bool] = try await send("DELETE", "v1/me/devices/\(deviceToken)", token: token)
    }

    func logout(token: String) async throws {
        let _: [String: Bool] = try await send("POST", "v1/auth/logout", token: token)
    }

    func deleteAccount(token: String) async throws {
        let _: [String: Bool] = try await send("DELETE", "v1/me", token: token)
    }

    // MARK: Plumbing

    private func send<T: Decodable>(_ method: String, _ path: String, token: String? = nil,
                                    body: [String: String]? = nil) async throws -> T {
        try await send(method, path, token: token, data: try body.map { try JSONEncoder().encode($0) })
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, token: String?,
                                                  encodable: B) async throws -> T {
        try await send(method, path, token: token, data: try JSONEncoder.api.encode(encodable))
    }

    private func send<T: Decodable>(_ method: String, _ path: String, token: String?, data: Data?) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let data {
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (responseData, response) = try await URLSession.shared.data(for: request)
        try check(responseData, response as? HTTPURLResponse)
        return try JSONDecoder.api.decode(T.self, from: responseData)
    }

    private func check(_ data: Data, _ http: HTTPURLResponse?) throws {
        guard let http, !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw APIError.unauthorized }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        throw APIError.server(http.statusCode, message ?? "Server error (HTTP \(http.statusCode)).")
    }
}
