import Foundation

/// Another Mac's sync state, as this Mac pulls it.
///
/// Syncing only ever pulls: each Mac takes the changes its peers made since
/// its own versions, and those that win a conflict with them, and tells its
/// peers when it has something new so they pull in turn.
public protocol SyncPeer: Sendable {
    /// Identifies the peer across connections, so a pull can resume where
    /// the last one from it left off.
    var id: String { get }

    /// The peer's item list, including removed items.
    func items() async throws -> [SyncItem]

    /// The peer's index of `itemID`: what changed since `position`, when
    /// the peer's index is still the one `position` is in, or else all of
    /// it. Nil when the peer isn't syncing the item right now.
    func records(forItem itemID: String, after position: IndexPosition?) async throws -> RecordBatch?

    /// Downloads the file at `path` in `itemID` to `destination`, which
    /// must not exist yet.
    func download(itemID: String, path: String, to destination: URL) async throws
}

/// A point in one Mac's index of one item.
public struct IndexPosition: Codable, Sendable, Hashable {
    /// Identifies the index. A Mac starts a new one when it launches, and
    /// whenever a path leaves the index, so a position in an old one says
    /// nothing about the new.
    public var index: String
    /// How many changes into the index the position is.
    public var sequence: Int64

    /// Creates a position.
    public init(index: String, sequence: Int64) {
        self.index = index
        self.sequence = sequence
    }
}

/// Part or all of a peer's index of one item.
public struct RecordBatch: Codable, Sendable, Equatable {
    /// Where the peer's index is now; asking after it returns only what
    /// changes from here on.
    public var position: IndexPosition
    /// Whether ``records`` is the whole index, rather than the records
    /// changed since the position asked after.
    public var isComplete: Bool
    /// The records.
    public var records: [FileRecord]

    /// Creates a batch.
    public init(position: IndexPosition, isComplete: Bool, records: [FileRecord]) {
        self.position = position
        self.isComplete = isComplete
        self.records = records
    }
}

/// What one pull from a peer did.
public struct SyncReport: Sendable, Equatable {
    /// Files downloaded.
    public var downloaded = 0
    /// Files and empty directories deleted.
    public var deleted = 0
    /// Files changed on this Mac that lost a conflict with a peer's
    /// concurrent change, and went to the Trash.
    public var conflicts = 0
    /// Paths that couldn't be synced this time. They are tried again on the
    /// next pull.
    public var failed = 0

    /// Creates an empty report.
    public init() {}
}

/// Why a folder or file can't be synced.
public enum SyncError: Error, LocalizedError, Equatable {
    /// Nothing exists at the path.
    case notFound(String)
    /// The path is the home folder, a folder holding it, a whole volume, or
    /// the root.
    case tooBroad(String)
    /// The path holds, or is inside, SyncThing's own state.
    case reserved(String)
    /// The path is already synced as part of `parent`.
    case insideSyncedItem(parent: String)
    /// The path contains `child`, which is synced on its own.
    case containsSyncedItem(child: String)

    /// A sentence for the user saying what's wrong.
    public var errorDescription: String? {
        switch self {
        case .notFound(let path): "Nothing exists at \(path)."
        case .tooBroad(let path): "\(path) is too broad to sync. Choose a folder inside it."
        case .reserved(let path): "\(path) holds SyncThing's own records, so it can't be synced."
        case .insideSyncedItem(let parent): "This is already synced as part of \(parent)."
        case .containsSyncedItem(let child): "This contains \(child), which is already synced. Remove it first."
        }
    }
}
