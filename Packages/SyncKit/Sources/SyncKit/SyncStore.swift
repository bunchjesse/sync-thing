import CryptoKit
import Foundation
import os

/// Keeps a Mac's sync state on disk: the item list and each item's index.
///
/// Every write replaces its file atomically, so a crash leaves either the
/// old state or the new one. The state is only this Mac's view; losing it
/// costs a rescan, never files.
struct SyncStore: Sendable {
    /// The directory the state lives in.
    let directory: URL

    private var itemsURL: URL { directory.appending(path: "items.json") }
    private var indexesURL: URL { directory.appending(path: "indexes", directoryHint: .isDirectory) }

    /// Creates a store in `directory`, creating it if needed.
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory.appending(path: "indexes"), withIntermediateDirectories: true)
    }

    /// The saved item list, including removed items; empty on first launch,
    /// or when the file can't be read.
    func loadItems() -> [SyncItem] {
        load([SyncItem].self, from: itemsURL) ?? []
    }

    /// Saves the item list.
    func save(items: [SyncItem]) throws {
        try Self.encoder.encode(items.sorted { $0.id < $1.id }).write(to: itemsURL, options: .atomic)
    }

    /// The saved index of `itemID`, or nil when it was never scanned or
    /// can't be read.
    func loadIndex(itemID: String) -> [String: FileRecord]? {
        guard let records = load([FileRecord].self, from: indexURL(itemID: itemID)) else { return nil }
        return Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Saves the index of `itemID`.
    func save(index: [String: FileRecord], itemID: String) throws {
        let records = index.values.sorted { $0.path < $1.path }
        try Self.encoder.encode(records).write(to: indexURL(itemID: itemID), options: .atomic)
    }

    /// Deletes the index of `itemID`.
    func removeIndex(itemID: String) {
        try? FileManager.default.removeItem(at: indexURL(itemID: itemID))
    }

    /// The items waiting for the user's ``JoinChoice``; empty when none are,
    /// or when the file can't be read.
    func loadAwaitingChoice() -> Set<String> {
        load(Set<String>.self, from: awaitingChoiceURL) ?? []
    }

    /// Saves the items waiting for the user's ``JoinChoice``.
    func save(awaitingChoice: Set<String>) throws {
        try Self.encoder.encode(awaitingChoice.sorted()).write(to: awaitingChoiceURL, options: .atomic)
    }

    /// The file listing the items waiting for a ``JoinChoice``.
    private var awaitingChoiceURL: URL { directory.appending(path: "awaiting-choice.json") }

    /// The file holding `itemID`'s index, named by a hash of the ID since
    /// the ID is a path.
    private func indexURL(itemID: String) -> URL {
        let digest = SHA256.hash(data: Data(itemID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return indexesURL.appending(path: "\(digest).json")
    }

    /// Decodes the file at `url`, or nil when there is none. A file that
    /// exists but doesn't decode is renamed with a `.corrupt` extension, so
    /// the next save doesn't destroy it.
    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            Self.log.error("Couldn't read \(url.lastPathComponent, privacy: .public); keeping it aside: \(error.localizedDescription, privacy: .public)")
            let aside = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    private static let log = Logger(subsystem: "dev.bunch.SyncKit", category: "store")
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
