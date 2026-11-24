import Foundation

/// Another Mac's sync state, as this Mac pulls it.
///
/// Syncing only ever pulls: each Mac downloads what its peers have that is
/// newer, and tells them when it has something new so they pull in turn.
public protocol SyncPeer: Sendable {
    /// The peer's item list, including removed items.
    func items() async throws -> [SyncItem]

    /// The peer's index of `itemID`, or nil when the peer isn't syncing it
    /// right now.
    func records(forItem itemID: String) async throws -> [FileRecord]?

    /// Downloads the file at `path` in `itemID` to `destination`, which
    /// must not exist yet.
    func download(itemID: String, path: String, to destination: URL) async throws
}

/// What one pull from a peer did.
public struct SyncReport: Sendable, Equatable {
    /// Files downloaded.
    public var downloaded = 0
    /// Files and empty directories deleted.
    public var deleted = 0
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
