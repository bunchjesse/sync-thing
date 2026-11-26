import CryptoKit
import Foundation

/// Builds an item's index from what is on disk.
///
/// A scan compares the disk with the item's previous index: an unchanged
/// file (same size and modification time) keeps its record without being
/// read again, a new or changed file is hashed, and a path that is gone
/// becomes a tombstone. Every call blocks on the file system, so callers run
/// it off the cooperative thread pool.
enum FileScanner {
    /// What a scan found.
    enum Outcome: Equatable {
        /// The item's records, keyed by path.
        case scanned([String: FileRecord])
        /// The item's root isn't there to scan — a folder that doesn't exist,
        /// or a file whose folder doesn't exist or that became a folder or a
        /// symbolic link — so nothing can be said about its contents.
        /// Reporting that instead of a deletion of everything is what keeps
        /// an unmounted drive from emptying the item on every Mac.
        case rootMissing
    }

    /// Names that are never synced: the bookkeeping Finder, Spotlight, and
    /// the file system keep in folders.
    static let ignoredNames: Set<String> = [".DS_Store", ".localized", ".TemporaryItems", ".Trashes", ".fseventsd", ".Spotlight-V100"]

    /// How long a tombstone is kept. A Mac that has been away longer may
    /// bring a deleted file back.
    static let tombstoneLifetime: SyncTimestamp = 90 * 24 * 60 * 60 * 1000

    /// Whether `name` is never synced.
    static func isIgnored(_ name: String) -> Bool {
        ignoredNames.contains(name)
    }

    /// Scans `root`, an item of `kind`, against its `previous` records.
    /// `now` caps versions, so a file stamped in the future can't outrank
    /// every later change, and is the latest a deletion can be dated.
    ///
    /// A path the scan can't vouch for keeps its previous records, as does
    /// everything under it, so it never looks like a deletion: a folder
    /// macOS won't list, a file whose attributes can't be read, or a path
    /// that became a symbolic link, which isn't synced. A deletion is dated
    /// by its folder's modification time, which is when the folder last
    /// lost an entry, rather than by when the scan noticed it.
    static func scan(
        root: URL,
        kind: SyncItem.Kind,
        previous: [String: FileRecord],
        now: SyncTimestamp
    ) -> Outcome {
        var found: [String: FileRecord] = [:]
        var unknown: [String] = []
        switch kind {
        case .folder:
            guard isDirectory(root), (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) != nil else {
                return .rootMissing
            }
            var pending: [String] = [""]
            while let directory = pending.popLast() {
                let directoryURL = directory.isEmpty ? root : root.appending(path: directory, directoryHint: .isDirectory)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path(percentEncoded: false)) else {
                    unknown.append(directory)
                    continue
                }
                for name in names where !isIgnored(name) {
                    let path = directory.isEmpty ? name : directory + "/" + name
                    let url = root.appending(path: path)
                    guard let values = try? url.resourceValues(forKeys: scanKeys), values.isSymbolicLink != true else {
                        unknown.append(path)
                        continue
                    }
                    if values.isDirectory == true {
                        found[path] = directoryRecord(path: path, url: url, previous: previous[path], now: now)
                        pending.append(path)
                    } else if values.isRegularFile == true {
                        guard let record = fileRecord(path: path, url: url, values: values, previous: previous[path], now: now) else {
                            unknown.append(path)
                            continue
                        }
                        found[path] = record
                    }
                }
            }
        case .file:
            guard isDirectory(root.deletingLastPathComponent()) else { return .rootMissing }
            var root = root
            root.removeAllCachedResourceValues()
            if let values = try? root.resourceValues(forKeys: scanKeys) {
                // A folder or link where the file was isn't the item any
                // more; like a missing folder, that pauses it.
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return .rootMissing }
                if let record = fileRecord(path: "", url: root, values: values, previous: previous[""], now: now) {
                    found[""] = record
                } else {
                    unknown.append("")
                }
            } else if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
                unknown.append("")
            }
        }

        var deletionTimes: [String: SyncTimestamp] = [:]
        for (path, record) in previous where found[path] == nil {
            if unknown.contains(where: { isSameOrInside(path, $0) }) {
                found[path] = record
            } else if !record.isDeleted {
                let deleted = deletionTime(of: path, root: root, kind: kind, now: now, cache: &deletionTimes)
                found[path] = record.deleted(at: max(deleted, record.version + 1))
            } else if now - record.version < tombstoneLifetime {
                found[path] = record
            }
        }
        return .scanned(found)
    }

    private static let scanKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    /// The latest `path` can have been deleted: the modification time of the
    /// nearest folder above it that still exists, which changed when it lost
    /// the entry, and never later than `now`. `cache` holds the times already
    /// looked up, by folder.
    private static func deletionTime(of path: String, root: URL, kind: SyncItem.Kind, now: SyncTimestamp, cache: inout [String: SyncTimestamp]) -> SyncTimestamp {
        guard kind == .folder else {
            return min(now, modificationTime(of: root.deletingLastPathComponent()) ?? now)
        }
        var folder = (path as NSString).deletingLastPathComponent
        while true {
            if let cached = cache[folder] { return cached }
            let url = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
            if let modified = modificationTime(of: url), isDirectory(url) {
                let time = min(now, modified)
                cache[folder] = time
                return time
            }
            guard !folder.isEmpty else { return now }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// The modification time of whatever is at `url`, or nil when nothing is.
    private static func modificationTime(of url: URL) -> SyncTimestamp? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.syncTimestamp
    }

    /// `timestamp` as a version made by `now`: never before 1970 or after
    /// `now`.
    private static func version(_ timestamp: SyncTimestamp, cappedAt now: SyncTimestamp) -> SyncTimestamp {
        min(max(timestamp, 0), now)
    }

    /// Whether `path` is `ancestor` or inside it; the empty path is the root.
    private static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        ancestor.isEmpty || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// The SHA-256 of the file at `url` as lowercase hex, read in chunks so a
    /// large file never sits in memory whole.
    static func hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `url` is a directory, following a symbolic link at the root.
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The record for the file at `url`: the previous one when the file is
    /// unchanged, otherwise a new version. A file with no history takes its
    /// modification time as its version; one that replaces an older record
    /// goes after it, even when its modification time is older, as a
    /// restored or copied file's is. Nil when the file can't be read, which
    /// the scan treats as unknown rather than deleted.
    private static func fileRecord(path: String, url: URL, values: URLResourceValues, previous: FileRecord?, now: SyncTimestamp) -> FileRecord? {
        guard let fileSize = values.fileSize, let modifiedDate = values.contentModificationDate else { return nil }
        let size = Int64(fileSize)
        let modified = modifiedDate.syncTimestamp
        if let previous, !previous.isDeleted, previous.kind == .file, previous.size == size, previous.modified == modified {
            return previous
        }
        guard let hash = try? hash(of: url) else { return nil }
        if let previous, !previous.isDeleted, previous.kind == .file, previous.hash == hash {
            var touched = previous
            touched.size = size
            touched.modified = modified
            return touched
        }
        let base = version(modified, cappedAt: now)
        let version = previous.map { max(base, $0.version + 1) } ?? base
        return FileRecord(path: path, kind: .file, version: version, size: size, modified: modified, hash: hash)
    }

    /// The record for the directory at `url`: the previous one while the
    /// directory stays, otherwise a new version.
    private static func directoryRecord(path: String, url: URL, previous: FileRecord?, now: SyncTimestamp) -> FileRecord {
        if let previous, !previous.isDeleted, previous.kind == .directory {
            return previous
        }
        let modified = modificationTime(of: url) ?? now
        let version = previous.map { max(now, $0.version + 1) } ?? version(modified, cappedAt: now)
        return FileRecord(path: path, kind: .directory, version: version, modified: modified)
    }
}
