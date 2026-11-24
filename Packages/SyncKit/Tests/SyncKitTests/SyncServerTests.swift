import Foundation
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

        let peer = HTTPSyncPeer(port: port, token: tokens.token(for: "laptop-id"))
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
            _ = try await HTTPSyncPeer(port: port, token: "not-issued").items()
        }
        let token = tokens.token(for: "laptop-id")
        tokens.revoke("laptop-id")
        await #expect(throws: URLError.self) {
            _ = try await HTTPSyncPeer(port: port, token: token).items()
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

        try await HTTPSyncPeer(port: port, token: tokens.token(for: "laptop-id")).announceChange()
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
        let peer = HTTPSyncPeer(port: port, token: tokens.token(for: "laptop-id"))

        await #expect(throws: URLError.self) {
            try await peer.download(itemID: "~/Notes", path: "../secret.txt", to: directory.url.appending(path: "out"))
        }
        #expect(try await peer.records(forItem: "~/Other") == nil)
    }
}
