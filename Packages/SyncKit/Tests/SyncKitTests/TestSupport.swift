import Foundation
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
