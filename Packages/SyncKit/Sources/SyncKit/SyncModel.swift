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

/// Which changes a version of a path has seen: for each Mac that changed
/// the path, a counter that grows with every change that Mac made.
///
/// Comparing two vectors says whether one version came after the other — a
/// Mac changed the path having seen the other version — or whether they are
/// concurrent: made on different Macs, neither having seen the other's.
/// Only concurrent versions conflict, so no Mac's clock decides between two
/// changes made in turn.
///
/// A counter goes to the larger of one more and the current time, so a Mac
/// that lost its state never reuses a counter it already gave out.
public struct VersionVector: Codable, Sendable, Hashable {
    /// How one vector relates to another.
    enum Order {
        /// Both saw the same changes.
        case equal
        /// The other vector saw every change this one did, and more.
        case before
        /// This vector saw every change the other did, and more.
        case after
        /// Each saw a change the other didn't.
        case concurrent
    }

    /// The most Macs a peer's vector may name.
    static let maximumMacs = 64

    /// The longest Mac ID a peer's vector may hold.
    static let maximumMacIDLength = 64

    /// Each Mac's counter.
    public private(set) var counters: [String: Int64]

    /// Creates a vector with `counters`.
    public init(_ counters: [String: Int64] = [:]) {
        self.counters = counters
    }

    /// Decodes the vector from a JSON object of counters by Mac.
    public init(from decoder: any Decoder) throws {
        counters = try decoder.singleValueContainer().decode([String: Int64].self)
    }

    /// Encodes the vector as a JSON object of counters by Mac.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(counters)
    }

    /// How this vector relates to `other`.
    func compare(to other: VersionVector) -> Order {
        var isBehind = false
        var isAhead = false
        for mac in Set(counters.keys).union(other.counters.keys) {
            let mine = counters[mac, default: 0]
            let theirs = other.counters[mac, default: 0]
            if mine < theirs { isBehind = true }
            if mine > theirs { isAhead = true }
        }
        switch (isBehind, isAhead) {
        case (false, false): return .equal
        case (true, false): return .before
        case (false, true): return .after
        case (true, true): return .concurrent
        }
    }

    /// The vector that has seen every change either this one or `other`
    /// has.
    func merged(with other: VersionVector) -> VersionVector {
        VersionVector(counters.merging(other.counters, uniquingKeysWith: max))
    }

    /// The vector of a change `mac` makes at `now` to a version with this
    /// vector.
    func incremented(for mac: String, now: SyncTimestamp) -> VersionVector {
        var counters = counters
        counters[mac] = max(counters[mac, default: 0] + 1, now)
        return VersionVector(counters)
    }

    /// Whether this vector sorts before `other` in an order every Mac
    /// agrees on, for breaking ties between concurrent versions.
    func sortsBefore(_ other: VersionVector) -> Bool {
        let mine = counters.sorted { $0.key < $1.key }
        let theirs = other.counters.sorted { $0.key < $1.key }
        return mine.lexicographicallyPrecedes(theirs) { ($0.key, $0.value) < ($1.key, $1.value) }
    }

    /// Whether a peer's vector is one a working Mac could have made by
    /// `now`: at least one Mac and at most ``maximumMacs``, each with a
    /// short ID free of control characters and a positive counter no
    /// further ahead of `now` than a timestamp may be. Counters follow the
    /// clock, so one far ahead is a broken peer, and would leave no room for
    /// the next change.
    func isPlausible(now: SyncTimestamp) -> Bool {
        (1...Self.maximumMacs).contains(counters.count) && counters.allSatisfy { mac, counter in
            (1...Self.maximumMacIDLength).contains(mac.utf8.count)
                && !mac.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && counter >= 1 && SyncEngine.isPlausible(counter, now: now)
        }
    }
}

/// What one Mac knows about one path inside a synced item.
///
/// Records are compared across Macs by their ``version``: one that has seen
/// another's changes replaces it, whatever the clocks say. Two concurrent
/// versions — changed on two Macs before either saw the other's — conflict,
/// and ``winsConflict(over:)`` picks the same winner on every Mac. A
/// deleted path keeps its record as a tombstone so the deletion reaches
/// Macs that still have the file instead of the file coming back.
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

    /// Which changes to the path this version has seen.
    public var version: VersionVector

    /// When this version came to be: the file's modification time, but no
    /// later than the scan that found it, or when the path was deleted.
    /// Decides conflicts between concurrent versions, and how old a
    /// tombstone is.
    public var changed: SyncTimestamp

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
        version: VersionVector,
        changed: SyncTimestamp,
        size: Int64 = 0,
        modified: SyncTimestamp,
        hash: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.isDeleted = isDeleted
        self.version = version
        self.changed = changed
        self.size = size
        self.modified = modified
        self.hash = hash
    }

    /// A tombstone recording that this path was deleted, as `version`, at
    /// `time`.
    func deleted(as version: VersionVector, at time: SyncTimestamp) -> FileRecord {
        FileRecord(path: path, kind: kind, isDeleted: true, version: version, changed: time, modified: time)
    }

    /// Whether this record, a peer's, should replace `other`, this Mac's
    /// record of the same path: it has seen `other`'s changes and more, or
    /// the two have the same or concurrent versions and it wins the
    /// conflict.
    func supersedes(_ other: FileRecord) -> Bool {
        switch version.compare(to: other.version) {
        case .after: true
        case .before: false
        case .equal, .concurrent: winsConflict(over: other)
        }
    }

    /// Whether this version wins a conflict with `other`, a concurrent
    /// version of the same path, the same way on every Mac. A file or
    /// directory beats a deletion, so a concurrent edit is never lost to
    /// it; otherwise the later change wins. Ties go to a directory, which
    /// may hold files, then to the larger hash, then to the version that
    /// sorts last.
    func winsConflict(over other: FileRecord) -> Bool {
        if isDeleted != other.isDeleted { return !isDeleted }
        if changed != other.changed { return changed > other.changed }
        if kind != other.kind { return kind == .directory }
        if hash != other.hash { return (hash ?? "") > (other.hash ?? "") }
        return other.version.sortsBefore(version)
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

/// Which copies win when items from the other Macs reach copies this Mac
/// already had before it synced them.
public enum JoinChoice: Sendable {
    /// This Mac takes the other Macs' files. Its own that differ, or that
    /// only it has, go to the Trash.
    case useOtherMacs
    /// The other Macs take this Mac's files. Theirs that differ are
    /// replaced, and files only they have go to their Trash.
    case useThisMac
}

/// The items whose copies on this Mac, made before it synced them, differ
/// from the other Macs', waiting for a ``JoinChoice``.
public struct JoinQuestion: Sendable, Hashable {
    /// One item whose copies differ.
    public struct Item: Sendable, Hashable, Identifiable {
        /// The item's portable path.
        public let id: String
        /// How many files differ between this Mac and the others,
        /// counting files only one side has.
        public let differingFiles: Int

        /// Creates an item.
        public init(id: String, differingFiles: Int) {
            self.id = id
            self.differingFiles = differingFiles
        }
    }

    /// The items whose copies differ, sorted by path.
    public let items: [Item]

    /// Creates a question.
    public init(items: [Item]) {
        self.items = items
    }
}
