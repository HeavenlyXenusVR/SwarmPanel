import Foundation

/// Thin URLSession wrapper mirroring frontend/src/api.js's apiFetch: attaches
/// a bearer token, JSON-encodes/decodes snake_case bodies, and surfaces
/// `{"detail": ...}` error payloads as APIError.server(...).
final class APIClient {
    static let shared = APIClient()

    /// The production backend is a stable named Cloudflare tunnel domain (not
    /// a rotating trycloudflare.com address), so it's safe to hardcode as the
    /// default — unlike the GitHub Pages web frontend, which reads
    /// live-config.json at runtime because it can't be rebuilt per tunnel
    /// change. A Settings screen (Phase 8) lets this be overridden for local
    /// development against the Docker container.
    static let defaultBaseURL = URL(string: "https://swarmpanel.xenusanimations.studio")!
    private static let baseURLDefaultsKey = "swarmpanel.baseURL"

    var baseURL: URL {
        get {
            if let stored = UserDefaults.standard.string(forKey: Self.baseURLDefaultsKey),
               let url = URL(string: stored) {
                return url
            }
            return Self.defaultBaseURL
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: Self.baseURLDefaultsKey)
        }
    }

    var token: String? {
        didSet { if let token { KeychainStore.save(token: token) } else { KeychainStore.clear() } }
    }

    /// Called by AppState when a request comes back 401 so every other
    /// in-flight/future call stops trying and the UI routes to Login.
    var onUnauthorized: (() -> Void)?

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// This app authenticates purely via a bearer token (Keychain-stored) —
    /// it never relies on cookies. `.shared` would use the device's shared
    /// cookie jar, which silently accumulates any `Set-Cookie` the backend
    /// happens to send (Starlette's SessionMiddleware sets one whenever a
    /// request touches `request.session`, e.g. the site-owner login path).
    /// A leftover session cookie from an earlier request, sent automatically
    /// on a later *unauthenticated* request like a fresh login POST (with no
    /// Authorization header yet and no Origin header, since native clients
    /// don't send one), trips the backend's
    /// "cookie without a trusted browser Origin" guard (app/security.py's
    /// _ensure_allowed_browser_origin) with a 403 — exactly the bug where
    /// logging out and back in failed with "Missing trusted browser origin."
    /// An ephemeral, cookie-disabled configuration keeps every request
    /// bearer-token-only, matching how this client actually authenticates.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    private init(session: URLSession = APIClient.makeSession()) {
        self.session = session
        self.token = KeychainStore.loadToken()

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    private struct EmptyBody: Encodable {}

    func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try await request(method: "GET", path: path, query: query, body: Optional<EmptyBody>.none)
    }

    func post<T: Decodable>(_ path: String) async throws -> T {
        try await request(method: "POST", path: path, query: [:], body: Optional<EmptyBody>.none)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request(method: "POST", path: path, query: [:], body: body)
    }

    /// Raw (non-JSON) download — used for CSV export files, which aren't a
    /// Decodable JSON body. Shares the same base URL + bearer-token attachment
    /// and error-payload handling as the generic request(_:) path.
    func downloadRaw(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidResponse }
        var urlRequest = URLRequest(url: url)
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.network(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                onUnauthorized?()
                throw APIError.unauthorized
            }
            let message = (try? decoder.decode(APIErrorPayload.self, from: data))?.detail?.message
                ?? "Download failed (\(httpResponse.statusCode))."
            throw APIError.server(statusCode: httpResponse.statusCode, message: message)
        }
        return data
    }

    private func request<T: Decodable, B: Encodable>(
        method: String,
        path: String,
        query: [String: String?],
        body: B?
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        let queryItems = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { throw APIError.invalidResponse }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body, !(body is EmptyBody) {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                onUnauthorized?()
                throw APIError.unauthorized
            }
            let message = (try? decoder.decode(APIErrorPayload.self, from: data))?.detail?.message
                ?? "Request failed (\(httpResponse.statusCode))."
            throw APIError.server(statusCode: httpResponse.statusCode, message: message)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
