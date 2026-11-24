import Foundation

/// A folder or file the user chose to keep in sync on every Mac.
///
/// The list of items is itself synced: each Mac merges the lists its peers
/// serve, newest change winning (``supersedes(_:)``), so an item added or
/// removed on one Mac is added or removed everywhere. Removing an item only
/// stops syncing it; its files stay where they are.
public struct SyncItem: Codable, Sendable, Hashable, Identifiable {
    /// What the item is on disk.
    public enum Kind: String, Codable, Sendable {
        case folder
        case file
    }

    /// The item's portable path (``SyncLocations``), which is also how every
    /// Mac identifies it.
    public let id: String

    /// Whether the item is a folder or a single file.
    public var kind: Kind

    /// When the item was last added or removed.
    public var version: SyncTimestamp

    /// Whether the item was removed from the list.
    public var isRemoved: Bool

    /// Creates an item.
    public init(id: String, kind: Kind, version: SyncTimestamp, isRemoved: Bool = false) {
        self.id = id
        self.kind = kind
        self.version = version
        self.isRemoved = isRemoved
    }

    /// Whether this entry should replace `other`, an entry for the same item:
    /// the newer change wins, and a removal wins a tie.
    func supersedes(_ other: SyncItem) -> Bool {
        if version != other.version {
            return version > other.version
        }
        return isRemoved && !other.isRemoved
    }
}

/// What one Mac knows about one path inside a synced item.
///
/// Records are compared across Macs to decide which copy wins: the higher
/// ``version`` does (``supersedes(_:)``). A deleted path keeps its record
/// as a tombstone so the deletion reaches Macs that still have the file
/// instead of the file coming back.
public struct FileRecord: Codable, Sendable, Hashable {
    /// What the path is on disk.
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
    }

    /// The path relative to the item's root, with `/` between components;
    /// empty for an item that is a single file.
    public var path: String

    /// Whether the path is a file or a directory.
    public var kind: Kind

    /// Whether the path was deleted.
    public var isDeleted: Bool

    /// When this version of the path came to be, for deciding which Mac's
    /// copy wins. Usually the file's modification time; later when a file
    /// replaces a deletion or a newer version that it predates.
    public var version: SyncTimestamp

    /// The file's size in bytes; zero for directories and deletions.
    public var size: Int64

    /// The file's modification time, which every Mac's copy keeps.
    public var modified: SyncTimestamp

    /// The SHA-256 of the file's contents, as lowercase hex; nil for
    /// directories and deletions.
    public var hash: String?

    /// Creates a record.
    public init(
        path: String,
        kind: Kind,
        isDeleted: Bool = false,
        version: SyncTimestamp,
        size: Int64 = 0,
        modified: SyncTimestamp,
        hash: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.isDeleted = isDeleted
        self.version = version
        self.size = size
        self.modified = modified
        self.hash = hash
    }

    /// A tombstone recording that this path was deleted at `version`.
    func deleted(at version: SyncTimestamp) -> FileRecord {
        FileRecord(path: path, kind: kind, isDeleted: true, version: version, modified: version)
    }

    /// Whether this record should replace `other`, a record for the same
    /// path on another Mac: the newer version wins. Ties, which take two
    /// edits in the same millisecond, go to a deletion and then to the
    /// larger hash, so every Mac picks the same winner.
    func supersedes(_ other: FileRecord) -> Bool {
        if version != other.version {
            return version > other.version
        }
        if isDeleted != other.isDeleted {
            return isDeleted
        }
        return (hash ?? "") > (other.hash ?? "")
    }

    /// Whether both records describe the same thing on disk, whatever their
    /// versions: both deleted, the same directory, or files with the same
    /// contents.
    func hasSameContent(as other: FileRecord) -> Bool {
        guard isDeleted == other.isDeleted else { return false }
        if isDeleted { return true }
        guard kind == other.kind else { return false }
        return kind == .directory || hash == other.hash
    }
}
