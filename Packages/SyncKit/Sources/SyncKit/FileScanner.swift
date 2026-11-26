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

    /// How long a tombstone is kept: about fifteen months. A Mac that has
    /// been away longer may bring a deleted file back.
    static let tombstoneLifetime: SyncTimestamp = 456 * 24 * 60 * 60 * 1000

    /// Whether `name` is never synced.
    static func isIgnored(_ name: String) -> Bool {
        ignoredNames.contains(name)
    }

    /// Scans `root`, an item of `kind`, against its `previous` records.
    /// Every change found — a new or edited file, a new directory, a
    /// deletion — becomes a new version by `mac` at `now`, after the
    /// version it replaces. `now` also caps change times, so a file stamped
    /// in the future can't win every conflict.
    ///
    /// A path the scan can't vouch for keeps its previous records, as does
    /// everything under it, so it never looks like a deletion: a folder
    /// macOS won't list, a file whose attributes can't be read, or a path
    /// that became a symbolic link, which isn't synced.
    static func scan(
        root: URL,
        kind: SyncItem.Kind,
        previous: [String: FileRecord],
        mac: String,
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
                        found[path] = directoryRecord(path: path, url: url, previous: previous[path], mac: mac, now: now)
                        pending.append(path)
                    } else if values.isRegularFile == true {
                        guard let record = fileRecord(path: path, url: url, values: values, previous: previous[path], mac: mac, now: now) else {
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
                if let record = fileRecord(path: "", url: root, values: values, previous: previous[""], mac: mac, now: now) {
                    found[""] = record
                } else {
                    unknown.append("")
                }
            } else if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
                unknown.append("")
            }
        }

        for (path, record) in previous where found[path] == nil {
            if unknown.contains(where: { isSameOrInside(path, $0) }) {
                found[path] = record
            } else if !record.isDeleted {
                found[path] = record.deleted(as: record.version.incremented(for: mac, now: now), at: now)
            } else if now - record.changed < tombstoneLifetime {
                found[path] = record
            }
        }
        return .scanned(found)
    }

    private static let scanKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    /// The modification time of whatever is at `url`, or nil when nothing is.
    private static func modificationTime(of url: URL) -> SyncTimestamp? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.syncTimestamp
    }

    /// `timestamp` as a change time found by `now`: never before 1970 or
    /// after `now`.
    private static func changeTime(_ timestamp: SyncTimestamp, cappedAt now: SyncTimestamp) -> SyncTimestamp {
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
    /// unchanged or only touched, otherwise a new version by `mac`. Nil
    /// when the file can't be read, which the scan treats as unknown rather
    /// than deleted.
    private static func fileRecord(path: String, url: URL, values: URLResourceValues, previous: FileRecord?, mac: String, now: SyncTimestamp) -> FileRecord? {
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
        let version = (previous?.version ?? VersionVector()).incremented(for: mac, now: now)
        return FileRecord(path: path, kind: .file, version: version, changed: changeTime(modified, cappedAt: now), size: size, modified: modified, hash: hash)
    }

    /// The record for the directory at `url`: the previous one while the
    /// directory stays, otherwise a new version by `mac`.
    private static func directoryRecord(path: String, url: URL, previous: FileRecord?, mac: String, now: SyncTimestamp) -> FileRecord {
        if let previous, !previous.isDeleted, previous.kind == .directory {
            return previous
        }
        let modified = modificationTime(of: url) ?? now
        let version = (previous?.version ?? VersionVector()).incremented(for: mac, now: now)
        return FileRecord(path: path, kind: .directory, version: version, changed: changeTime(modified, cappedAt: now), modified: modified)
    }
}
