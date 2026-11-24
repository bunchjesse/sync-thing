import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import SyncKit

/// A temporary directory that one test owns, deleted with ``remove()``.
struct TemporaryDirectory {
    /// The directory.
    let url: URL

    /// Creates an empty directory under the system's temporary directory.
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "SyncKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Deletes the directory and everything in it.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// One simulated Mac: an engine whose home folder and state live in a
/// temporary directory, and whose deletions are permanent rather than
/// going to the real Trash.
struct TestMac {
    /// The Mac's engine.
    let engine: SyncEngine
    /// The Mac's home folder.
    let home: URL

    /// Creates a Mac inside `directory`, named `name`.
    init(named name: String, in directory: TemporaryDirectory) throws {
        home = directory.url.appending(path: name, directoryHint: .isDirectory)
        let state = directory.url.appending(path: "\(name)-state", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        engine = try SyncEngine(
            locations: SyncLocations(home: home),
            stateDirectory: state,
            removeFile: { try FileManager.default.removeItem(at: $0) }
        )
    }

    /// The URL of `path` under this Mac's home folder.
    func url(_ path: String) -> URL {
        home.appending(path: path)
    }

    /// Writes `contents` to `path` under the home folder, creating folders
    /// on the way, with `modified` as its modification time when given.
    func write(_ contents: String, to path: String, modified: Date? = nil) throws {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    /// The contents of `path` under the home folder, or nil when there is
    /// no file there.
    func read(_ path: String) -> String? {
        (try? Data(contentsOf: url(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The modification time of `path` under the home folder.
    func modified(_ path: String) throws -> Date? {
        try url(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The modification time of `path` under the home folder as the engine
    /// records it.
    func timestamp(_ path: String) -> SyncTimestamp? {
        (try? modified(path))?.flatMap(\.self)?.syncTimestamp
    }

    /// Deletes `path` under the home folder.
    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: url(path))
    }

    /// Whether anything is at `path` under the home folder.
    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(path).path(percentEncoded: false))
    }

    /// Sets the modification time of `path` under the home folder, which
    /// may be a folder.
    func setModified(_ date: Date, of path: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(path).path(percentEncoded: false))
    }

    /// Everything under `path`: each file's contents, and `/` for each
    /// folder, by relative path. Finder's bookkeeping is left out.
    func tree(_ path: String) -> [String: String] {
        let root = url(path)
        let subpaths = (try? FileManager.default.subpathsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        var tree: [String: String] = [:]
        for subpath in subpaths where !subpath.split(separator: "/").contains(where: { FileScanner.isIgnored(String($0)) }) {
            let url = root.appending(path: subpath)
            tree[subpath] = FileScanner.isDirectory(url) ? "/" : (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }
        return tree
    }
}

/// A moment `seconds` before now, in whole milliseconds, for modification
/// times that must be in the past — the scanner treats later ones as now.
func ago(_ seconds: TimeInterval) -> Date {
    Date(syncTimestamp: Date.now.addingTimeInterval(-seconds).syncTimestamp)
}

/// A peer's record of a file at `path` holding `contents`.
func fileRecord(_ path: String, _ contents: String, version: SyncTimestamp, modified: SyncTimestamp? = nil) -> FileRecord {
    let hash = SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
    return FileRecord(path: path, kind: .file, version: version, size: Int64(contents.utf8.count), modified: modified ?? version, hash: hash)
}

/// A peer that serves a fixed item list, index, and file contents.
struct FixedPeer: SyncPeer {
    /// The item list to serve.
    var items: [SyncItem]
    /// The index served for every item; nil to say the peer isn't syncing
    /// it right now.
    var records: [FileRecord]? = []
    /// The contents served for each path; a path missing here fails.
    var contents: [String: String] = [:]

    func items() async throws -> [SyncItem] { items }

    func records(forItem itemID: String) async throws -> [FileRecord]? { records }

    func download(itemID: String, path: String, to destination: URL) async throws {
        guard let contents = contents[path] else { throw URLError(.fileDoesNotExist) }
        try Data(contents.utf8).write(to: destination)
    }
}

/// Has every Mac rescan and pull from every other, twice, so changes
/// reach every Mac whichever order they arrive in.
func syncAll(_ macs: [TestMac]) async throws {
    for _ in 0..<2 {
        for mac in macs {
            await mac.engine.rescanAll()
            for other in macs where other.home != mac.home {
                try await mac.pull(from: other)
            }
        }
    }
}

/// A peer that serves another engine like ``EnginePeer``, but lets a test
/// fail downloads or change what arrives.
struct FaultyPeer: SyncPeer {
    /// The engine being served.
    let base: EnginePeer
    /// Called with each download's path before it starts; throws to fail it.
    var beforeDownload: @Sendable (_ path: String) throws -> Void = { _ in }
    /// Paths whose download arrives with other contents than the index says,
    /// as when the file changes on the peer mid-download.
    var altered: Set<String> = []

    func items() async throws -> [SyncItem] {
        try await base.items()
    }

    func records(forItem itemID: String) async throws -> [FileRecord]? {
        try await base.records(forItem: itemID)
    }

    func download(itemID: String, path: String, to destination: URL) async throws {
        try beforeDownload(path)
        try await base.download(itemID: itemID, path: path, to: destination)
        if altered.contains(path) {
            try Data("changed mid-download".utf8).write(to: destination)
        }
    }
}

/// A count shared between a test and the closures it hands out.
final class Counter: Sendable {
    private let count = Mutex(0)

    /// Adds one and returns the new count.
    func increment() -> Int {
        count.withLock { count in
            count += 1
            return count
        }
    }
}

/// Every ``SyncEngine/Event`` an engine reports, in order.
final class EventLog: Sendable {
    private let events = Mutex<[SyncEngine.Event]>([])

    /// Starts recording `engine`'s events.
    init(engine: SyncEngine) async {
        await engine.observe { [weak self] event in
            self?.events.withLock { $0.append(event) }
        }
    }

    /// The events so far.
    var all: [SyncEngine.Event] {
        events.withLock { $0 }
    }

    /// Forgets the events so far.
    func clear() {
        events.withLock { $0.removeAll() }
    }
}

/// A peer that serves another engine directly, standing in for HTTP.
struct EnginePeer: SyncPeer {
    /// The engine being served.
    let engine: SyncEngine

    func items() async throws -> [SyncItem] {
        await engine.allItems()
    }

    func records(forItem itemID: String) async throws -> [FileRecord]? {
        await engine.records(forItem: itemID)
    }

    func download(itemID: String, path: String, to destination: URL) async throws {
        guard let source = await engine.servableFile(itemID: itemID, path: path) else {
            throw URLError(.fileDoesNotExist)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

extension TestMac {
    /// Pulls everything `other` has that is newer.
    @discardableResult
    func pull(from other: TestMac) async throws -> SyncReport {
        try await engine.pull(from: EnginePeer(engine: other.engine))
    }
}
