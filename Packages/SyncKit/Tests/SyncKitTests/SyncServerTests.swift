import Foundation
import Hummingbird
import Testing
@testable import SyncKit

/// The HTTP server and client the Macs use through their tunnels, run on
/// loopback in-process.
struct SyncServerTests {
    /// A Mac pulls a folder over HTTP with the token the host issued it, and
    /// file names with spaces, `+`, `&`, and non-ASCII characters survive.
    @Test func pullOverHTTP() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("hello", to: "Notes/a b+c&d.txt")
        try studio.write("café", to: "Notes/Résumé/ünïcode.md")
        try await studio.engine.addItem(at: studio.url("Notes"))

        let tokens = SyncTokens()
        let server = SyncServer(engine: studio.engine, tokens: tokens) { _ in }
        let port = try await server.start()
        defer { server.stop() }

        let peer = HTTPSyncPeer(id: "studio", port: port, token: tokens.token(for: "laptop-id"))
        let report = try await laptop.engine.pull(from: peer)

        #expect(report.downloaded == 2)
        #expect(laptop.read("Notes/a b+c&d.txt") == "hello")
        #expect(laptop.read("Notes/Résumé/ünïcode.md") == "café")
    }

    /// Requests without a token the host issued are turned away, and so
    /// are requests with a token it has since revoked.
    @Test func requestsNeedAnIssuedToken() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let tokens = SyncTokens()
        let server = SyncServer(engine: studio.engine, tokens: tokens) { _ in }
        let port = try await server.start()
        defer { server.stop() }

        await #expect(throws: URLError.self) {
            _ = try await HTTPSyncPeer(id: "studio", port: port, token: "not-issued").items()
        }
        let token = tokens.token(for: "laptop-id")
        tokens.revoke("laptop-id")
        await #expect(throws: URLError.self) {
            _ = try await HTTPSyncPeer(id: "studio", port: port, token: token).items()
        }
    }

    /// An announcement reaches the host tagged with the Mac whose token
    /// sent it.
    @Test func announcementNamesTheSender() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let tokens = SyncTokens()
        let (announced, continuation) = AsyncStream.makeStream(of: String.self)
        let server = SyncServer(engine: studio.engine, tokens: tokens) { continuation.yield($0) }
        let port = try await server.start()
        defer { server.stop() }

        try await HTTPSyncPeer(id: "studio", port: port, token: tokens.token(for: "laptop-id")).announceChange()
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            continuation.finish()
        }
        defer { timeout.cancel() }

        #expect(await announced.first { _ in true } == "laptop-id")
    }

    /// A path the host's index doesn't list as a file isn't served — not
    /// one that exists on disk outside the item, reached with `..`, and not
    /// an item the host doesn't sync.
    @Test func onlyIndexedFilesAreServed() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("synced", to: "Notes/a.txt")
        try studio.write("secret", to: "secret.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        let tokens = SyncTokens()
        let server = SyncServer(engine: studio.engine, tokens: tokens) { _ in }
        let port = try await server.start()
        defer { server.stop() }
        let peer = HTTPSyncPeer(id: "studio", port: port, token: tokens.token(for: "laptop-id"))

        await #expect(throws: URLError.self) {
            try await peer.download(itemID: "~/Notes", path: "../secret.txt", to: directory.url.appending(path: "out"))
        }
        #expect(try await peer.records(forItem: "~/Other", after: nil) == nil)
    }

    /// A server for `mac`'s engine, the token it issued, and the port it
    /// listens on.
    private func serve(_ mac: TestMac) async throws -> (server: SyncServer, tokens: SyncTokens, port: UInt16) {
        let tokens = SyncTokens()
        let server = SyncServer(engine: mac.engine, tokens: tokens) { _ in }
        let port = try await server.start()
        return (server, tokens, port)
    }

    /// The status code of a GET for `path` on `port`, with `authorization`
    /// as the header when given.
    private func status(_ path: String, port: UInt16, authorization: String?) async throws -> Int {
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/\(path)")))
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (_, response) = try await HTTPSyncPeer.session.data(for: request)
        return try #require(response as? HTTPURLResponse).statusCode
    }

    /// Requests missing a parameter, naming a directory, a deleted file, or
    /// an unknown route get 404, and requests without a proper bearer token
    /// get 401 before any of that is looked at.
    @Test func badRequestsAreTurnedAway() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("a", to: "Notes/Folder/a.txt")
        try studio.write("gone", to: "Notes/gone.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try studio.remove("Notes/gone.txt")
        await studio.engine.rescanAll()
        let (server, tokens, port) = try await serve(studio)
        defer { server.stop() }
        let bearer = "Bearer \(tokens.token(for: "laptop-id"))"

        #expect(try await status("v1/records", port: port, authorization: bearer) == 404)
        #expect(try await status("v1/file?item=~/Notes", port: port, authorization: bearer) == 404)
        #expect(try await status("v1/file?item=~/Notes&path=Folder", port: port, authorization: bearer) == 404)
        #expect(try await status("v1/file?item=~/Notes&path=gone.txt", port: port, authorization: bearer) == 404)
        #expect(try await status("v1/file?item=~/Notes&path=Folder/a.txt", port: port, authorization: bearer) == 200)
        #expect(try await status("v1/nothing", port: port, authorization: bearer) == 404)
        for authorization in [nil, "Basic abc", "Bearer ", "bearer \(tokens.token(for: "laptop-id"))", tokens.token(for: "laptop-id")] {
            #expect(try await status("v1/items", port: port, authorization: authorization) == 401)
        }
    }

    /// A token revoked partway through a pull — the tunnel closed — ends the
    /// pull, keeping what already arrived.
    @Test func revokedTokenEndsThePull() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        for index in 0..<3 {
            try studio.write("\(index)", to: "Notes/\(index).txt")
        }
        try await studio.engine.addItem(at: studio.url("Notes"))
        let (server, tokens, port) = try await serve(studio)
        defer { server.stop() }
        let peer = RevokingPeer(base: HTTPSyncPeer(id: "studio", port: port, token: tokens.token(for: "laptop-id")), tokens: tokens, endpointID: "laptop-id")

        await #expect(throws: URLError(.userAuthenticationRequired)) {
            try await laptop.engine.pull(from: peer)
        }
        #expect(laptop.tree("Notes").count == 1)
    }

    /// A peer that answers with a redirect isn't followed — it could aim
    /// this Mac's token at another port — so the request fails.
    @Test func redirectsAreRefused() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let (server, tokens, port) = try await serve(studio)
        defer { server.stop() }
        let router = Router()
        router.get("v1/items") { _, _ in
            Response(status: .found, headers: [.location: "http://127.0.0.1:\(port)/v1/items"])
        }
        let (ports, continuation) = AsyncStream.makeStream(of: Int.self)
        let redirector = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)), onServerRunning: {
            continuation.yield($0.localAddress?.port ?? 0)
        })
        let running = Task { try await redirector.run() }
        defer { running.cancel() }
        let redirectPort = try #require(await ports.first { _ in true })

        await #expect(throws: URLError(.badServerResponse)) {
            _ = try await HTTPSyncPeer(id: "studio", port: UInt16(redirectPort), token: tokens.token(for: "laptop-id")).items()
        }
    }

    /// Each Mac gets one token, the same every time it asks, and a new one
    /// after its old one is revoked; revoking one Mac's leaves the others.
    @Test func tokensArePerMac() {
        let tokens = SyncTokens()
        let laptop = tokens.token(for: "laptop")
        let mini = tokens.token(for: "mini")

        #expect(tokens.token(for: "laptop") == laptop)
        #expect(laptop != mini)
        #expect(laptop.count == 64)
        tokens.revoke("laptop")
        #expect(tokens.endpointID(for: laptop) == nil)
        #expect(tokens.endpointID(for: mini) == "mini")
        #expect(tokens.token(for: "laptop") != laptop)
    }

    /// Names that mean something in a URL — `%`, `?`, `#`, `+`, `&`, `=` —
    /// and a newline survive the trip over HTTP.
    @Test func oddNamesSurviveHTTP() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let names = ["100%.txt", "what?.txt", "#hash.txt", "a+b.txt", "a&b=c.txt", "new\nline.txt", "%2F.txt", "émoji 🎉.txt"]
        for name in names {
            try studio.write(name, to: "Notes/\(name)")
        }
        try await studio.engine.addItem(at: studio.url("Notes"))
        let (server, tokens, port) = try await serve(studio)
        defer { server.stop() }

        let report = try await laptop.engine.pull(from: HTTPSyncPeer(id: "studio", port: port, token: tokens.token(for: "laptop-id")))

        #expect(report.failed == 0)
        for name in names {
            #expect(laptop.read("Notes/\(name)") == name)
        }
    }

    /// Over HTTP, a position in the host's current index gets only what
    /// changed after it, and one from another index — the host relaunched
    /// — or a malformed or negative one gets the whole index.
    @Test func recordsAfterAPositionOverHTTP() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("a", to: "Notes/a.txt")
        try studio.write("b", to: "Notes/b.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        let (server, tokens, port) = try await serve(studio)
        defer { server.stop() }
        let peer = HTTPSyncPeer(id: "studio", port: port, token: tokens.token(for: "laptop-id"))

        let first = try #require(try await peer.records(forItem: "~/Notes", after: nil))
        try studio.write("b changed", to: "Notes/b.txt")
        await studio.engine.rescanAll()
        let delta = try #require(try await peer.records(forItem: "~/Notes", after: first.position))
        let stale = IndexPosition(index: "another", sequence: first.position.sequence)
        let whole = try #require(try await peer.records(forItem: "~/Notes", after: stale))
        let bearer = "Bearer \(tokens.token(for: "laptop-id"))"
        var malformed: [String: RecordBatch] = [:]
        for after in ["soon", "-1"] {
            var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/v1/records?item=~/Notes&index=\(first.position.index)&after=\(after)")))
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
            let (data, _) = try await HTTPSyncPeer.session.data(for: request)
            malformed[after] = try JSONDecoder().decode(RecordBatch.self, from: data)
        }

        #expect(first.isComplete)
        #expect(first.records.map(\.path) == ["a.txt", "b.txt"])
        #expect(!delta.isComplete)
        #expect(delta.records.map(\.path) == ["b.txt"])
        #expect(delta.position.index == first.position.index)
        #expect(whole.isComplete)
        #expect(whole.records.count == 2)
        #expect(malformed.count == 2)
        #expect(malformed.values.allSatisfy { $0.isComplete && $0.records.count == 2 })
    }
}

/// An HTTP peer whose host revokes this Mac's token after the first
/// download, as when the tunnel closes mid-pull.
private struct RevokingPeer: SyncPeer {
    /// The peer requests go to.
    let base: HTTPSyncPeer
    /// The host's tokens.
    let tokens: SyncTokens
    /// The Mac whose token is revoked.
    let endpointID: String

    var id: String { base.id }

    func items() async throws -> [SyncItem] {
        try await base.items()
    }

    func records(forItem itemID: String, after position: IndexPosition?) async throws -> RecordBatch? {
        try await base.records(forItem: itemID, after: position)
    }

    func download(itemID: String, path: String, to destination: URL) async throws {
        try await base.download(itemID: itemID, path: path, to: destination)
        tokens.revoke(endpointID)
    }
}
