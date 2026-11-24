import Foundation

/// A peer reached over HTTP through its tunnel's loopback port.
struct HTTPSyncPeer: SyncPeer {
    /// The tunnel's loopback address, `http://127.0.0.1:<port>`.
    let baseURL: URL
    /// The token the peer's host issued this Mac, sent with every request.
    let token: String
    /// The session requests go through.
    let session: URLSession

    /// Creates a peer whose tunnel listens on `port`, presenting `token`.
    init(port: UInt16, token: String, session: URLSession = HTTPSyncPeer.session) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        self.baseURL = components.url ?? URL(filePath: "/")
        self.token = token
        self.session = session
    }

    /// A session that keeps nothing on disk, never follows redirects — a
    /// peer could otherwise point requests at other ports on this Mac —
    /// and gives up when a peer goes quiet instead of waiting out the
    /// system default.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: RefusesRedirects(), delegateQueue: nil)
    }()

    func items() async throws -> [SyncItem] {
        let (data, _) = try await send(request(path: "v1/items"))
        return try JSONDecoder().decode([SyncItem].self, from: data)
    }

    func records(forItem itemID: String) async throws -> [FileRecord]? {
        let (data, response) = try await send(request(path: "v1/records", query: ["item": itemID]), allowing: [404])
        guard response.statusCode != 404 else { return nil }
        return try JSONDecoder().decode([FileRecord].self, from: data)
    }

    func download(itemID: String, path: String, to destination: URL) async throws {
        let (location, response) = try await session.download(for: request(path: "v1/file", query: ["item": itemID, "path": path]))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: location)
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: location, to: destination)
    }

    /// Tells the peer this Mac has something new, so it pulls.
    func announceChange() async throws {
        var request = request(path: "v1/changed")
        request.httpMethod = "POST"
        _ = try await send(request)
    }

    /// The characters a query value may hold unescaped. `+`, `&`, and `=`
    /// are left out: they're allowed in a URL query but mean something to
    /// the server's query parser.
    private static let queryValueCharacters = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))

    private func request(path: String, query: [String: String] = [:]) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            let encoded = query.sorted { $0.key < $1.key }.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: Self.queryValueCharacters) ?? "")"
            }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.percentEncodedQuery = encoded.joined(separator: "&")
            url = components?.url ?? url
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest, allowing allowed: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) || allowed.contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Answers every redirect by staying put, so the redirect response itself
/// is what the request returns.
private final class RefusesRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
