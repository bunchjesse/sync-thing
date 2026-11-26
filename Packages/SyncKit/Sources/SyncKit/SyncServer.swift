import Foundation
import Hummingbird
import NIOCore
import os
import Synchronization

/// The HTTP server other Macs pull from, reachable only through their
/// tunnels.
///
/// It listens on `127.0.0.1` alone, and every request must carry a bearer
/// token that ``RemoteHostService`` handed to one of the account's Macs
/// (``SyncTokens``), so another process on this Mac can't read synced
/// files through it.
///
/// | Request | Response |
/// |---------|----------|
/// | `GET /v1/items` | Every ``SyncItem``, including removed ones |
/// | `GET /v1/records?item=<id>[&index=<index>&after=<sequence>]` | A ``RecordBatch`` of the item's ``FileRecord``s — only those changed after the ``IndexPosition`` given, when it is in the current index — or 404 when the item isn't synced here, is missing, or is held for a ``JoinChoice`` |
/// | `GET /v1/file?item=<id>&path=<path>` | The file's contents, or 404 when the records would be |
/// | `POST /v1/changed` | 204; this Mac pulls from the caller soon |
final class SyncServer: Sendable {
    /// The port the server is listening on, once it is.
    var port: UInt16? { state.withLock { $0.port } }

    private struct State {
        var port: UInt16?
        var task: Task<Void, Never>?
    }

    private let engine: SyncEngine
    private let tokens: SyncTokens
    private let onPeerChanged: @Sendable (_ endpointID: String) -> Void
    private let state = Mutex(State())

    private static let log = Logger(subsystem: "dev.bunch.SyncKit", category: "server")

    /// Creates a server for `engine`, authorizing requests with `tokens`.
    /// `onPeerChanged` receives the endpoint ID of a Mac that says it has
    /// something new.
    init(engine: SyncEngine, tokens: SyncTokens, onPeerChanged: @escaping @Sendable (_ endpointID: String) -> Void) {
        self.engine = engine
        self.tokens = tokens
        self.onPeerChanged = onPeerChanged
    }

    /// Starts listening on a free loopback port and returns it.
    @discardableResult
    func start() async throws -> UInt16 {
        let router = Router(context: SyncRequestContext.self)
        router.add(middleware: TokenMiddleware(tokens: tokens))
        let engine = engine
        let onPeerChanged = onPeerChanged

        router.get("v1/items") { _, _ in
            try Self.json(await engine.allItems())
        }
        router.get("v1/records") { request, _ in
            let parameters = request.uri.queryParameters
            guard let itemID = parameters["item"].map(String.init) else {
                throw HTTPError(.notFound)
            }
            let sequence = parameters["after"].flatMap { Int64($0) }.flatMap { $0 >= 0 ? $0 : nil }
            let position = parameters["index"].flatMap { index in
                sequence.map { IndexPosition(index: String(index), sequence: $0) }
            }
            guard let batch = await engine.records(forItem: itemID, after: position) else {
                throw HTTPError(.notFound)
            }
            return try Self.json(batch)
        }
        router.get("v1/file") { request, context in
            guard let itemID = request.uri.queryParameters["item"].map(String.init),
                  let path = request.uri.queryParameters["path"].map(String.init),
                  let url = await engine.servableFile(itemID: itemID, path: path) else {
                throw HTTPError(.notFound)
            }
            let body = try await FileIO().loadFile(path: url.path(percentEncoded: false), context: context)
            return Response(status: .ok, headers: [.contentType: "application/octet-stream"], body: body)
        }
        router.post("v1/changed") { _, context in
            if let endpointID = context.peerEndpointID {
                onPeerChanged(endpointID)
            }
            return Response(status: .noContent)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: UInt16.self)
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: nil),
            onServerRunning: { channel in
                continuation.yield(UInt16(channel.localAddress?.port ?? 0))
                continuation.finish()
            }
        )
        let task = Task { [weak self] in
            do {
                try await app.run()
            } catch {
                Self.log.error("The sync server stopped: \(error.localizedDescription, privacy: .public)")
            }
            continuation.finish()
            self?.state.withLock { $0.port = nil }
        }
        state.withLock { $0.task = task }
        guard let port = await stream.first(where: { _ in true }), port != 0 else {
            task.cancel()
            throw URLError(.cannotFindHost)
        }
        state.withLock { $0.port = port }
        return port
    }

    /// Stops the server.
    func stop() {
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
            state.port = nil
        }
    }

    private static func json(_ value: some Encodable) throws -> Response {
        let data = try JSONEncoder().encode(value)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}

/// The access tokens the account's Macs present to this Mac's
/// ``SyncServer``, one per Mac, issued when its tunnel is admitted.
///
/// Tokens live in memory only: after a relaunch every Mac reconnects and is
/// issued a new one.
final class SyncTokens: Sendable {
    private let tokens = Mutex<[String: String]>([:])

    /// The token for `endpointID`, issuing one on first use.
    func token(for endpointID: String) -> String {
        tokens.withLock { tokens in
            if let existing = tokens.first(where: { $0.value == endpointID }) {
                return existing.key
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "The system random number generator failed")
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            tokens[token] = endpointID
            return token
        }
    }

    /// Stops accepting `endpointID`'s token.
    func revoke(_ endpointID: String) {
        tokens.withLock { tokens in
            tokens = tokens.filter { $0.value != endpointID }
        }
    }

    /// The Mac `token` was issued to, or nil when it wasn't.
    func endpointID(for token: String) -> String? {
        tokens.withLock { $0[token] }
    }
}

/// A request to the ``SyncServer``, with the Mac its token belongs to.
struct SyncRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    /// The endpoint ID of the Mac that made the request, once its token is checked.
    var peerEndpointID: String?

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
    }
}

/// Turns away every request without a token ``SyncTokens`` issued.
struct TokenMiddleware: RouterMiddleware {
    typealias Context = SyncRequestContext

    let tokens: SyncTokens

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer "),
              let endpointID = tokens.endpointID(for: String(authorization.dropFirst("Bearer ".count))) else {
            throw HTTPError(.unauthorized)
        }
        var context = context
        context.peerEndpointID = endpointID
        return try await next(request, context)
    }
}
