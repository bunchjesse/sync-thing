import Foundation
import Testing
@testable import SyncKit

struct SyncLocationsTests {
    /// Paths in the home folder are written relative to it, so they mean
    /// the same folder on a Mac with another user name.
    @Test func homePathsArePortable() {
        let alice = SyncLocations(home: URL(filePath: "/Users/alice"))
        let bob = SyncLocations(home: URL(filePath: "/Users/bob"))

        let id = alice.portablePath(for: URL(filePath: "/Users/alice/Documents/Notes"))

        #expect(id == "~/Documents/Notes")
        #expect(bob.url(forPortablePath: id).path(percentEncoded: false) == "/Users/bob/Documents/Notes")
    }

    /// Paths outside the home folder stay absolute, and a sibling whose name
    /// starts with the home folder's isn't mistaken for being inside it.
    @Test func otherPathsStayAbsolute() {
        let locations = SyncLocations(home: URL(filePath: "/Users/alice"))

        #expect(locations.portablePath(for: URL(filePath: "/Volumes/Data/Photos")) == "/Volumes/Data/Photos")
        #expect(locations.portablePath(for: URL(filePath: "/Users/alice2/Notes")) == "/Users/alice2/Notes")
        #expect(locations.portablePath(for: URL(filePath: "/Users/alice")) == "~")
    }

    /// Millisecond timestamps survive a round trip through `Date`.
    @Test func timestampsRoundTripThroughDate() {
        let timestamp: SyncTimestamp = 1_795_000_000_123
        #expect(Date(syncTimestamp: timestamp).syncTimestamp == timestamp)
    }
}

struct FileRecordTests {
    /// The newer version wins.
    @Test func newerVersionWins() {
        let old = FileRecord(path: "a", kind: .file, version: 1, modified: 1, hash: "x")
        let new = FileRecord(path: "a", kind: .file, version: 2, modified: 2, hash: "y")

        #expect(new.supersedes(old))
        #expect(!old.supersedes(new))
    }

    /// A tie goes the same way on both Macs: deletion first, then the
    /// larger hash.
    @Test func tiesAreBrokenTheSameWayEverywhere() {
        let file = FileRecord(path: "a", kind: .file, version: 5, modified: 5, hash: "a")
        let other = FileRecord(path: "a", kind: .file, version: 5, modified: 5, hash: "b")
        let tombstone = file.deleted(at: 5)

        #expect(tombstone.supersedes(file))
        #expect(!file.supersedes(tombstone))
        #expect(other.supersedes(file))
        #expect(!file.supersedes(other))
    }

    /// An item's newer entry wins, and a removal wins a tie.
    @Test func itemEntriesMerge() {
        let added = SyncItem(id: "~/A", kind: .folder, version: 5)
        let removed = SyncItem(id: "~/A", kind: .folder, version: 5, isRemoved: true)
        let readded = SyncItem(id: "~/A", kind: .folder, version: 6)

        #expect(removed.supersedes(added))
        #expect(readded.supersedes(removed))
        #expect(!added.supersedes(removed))
    }
}

struct FileScannerTests {
    /// A folder's files and subfolders get records; Finder's bookkeeping
    /// doesn't.
    @Test func scanRecordsFilesAndFolders() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appending(path: "Notes")
        try FileManager.default.createDirectory(at: root.appending(path: "Sub"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appending(path: "one.txt"))
        try Data("two".utf8).write(to: root.appending(path: "Sub/two.txt"))
        try Data().write(to: root.appending(path: ".DS_Store"))

        guard case .scanned(let records) = FileScanner.scan(root: root, kind: .folder, previous: [:], now: 1) else {
            Issue.record("scan didn't find the folder")
            return
        }

        #expect(Set(records.keys) == ["one.txt", "Sub", "Sub/two.txt"])
        #expect(records["one.txt"]?.hash == "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed")
        #expect(records["Sub"]?.kind == .directory)
    }

    /// An unchanged file keeps its record; a deleted one becomes a tombstone
    /// newer than the version it replaces.
    @Test func rescanKeepsUnchangedAndTombstonesDeleted() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url
        try Data("keep".utf8).write(to: root.appending(path: "keep.txt"))
        try Data("gone".utf8).write(to: root.appending(path: "gone.txt"))
        guard case .scanned(let first) = FileScanner.scan(root: root, kind: .folder, previous: [:], now: 1) else {
            Issue.record("scan didn't find the folder")
            return
        }

        try FileManager.default.removeItem(at: root.appending(path: "gone.txt"))
        let later = Date().syncTimestamp
        guard case .scanned(let second) = FileScanner.scan(root: root, kind: .folder, previous: first, now: later) else {
            Issue.record("scan didn't find the folder")
            return
        }

        #expect(second["keep.txt"] == first["keep.txt"])
        let tombstone = try #require(second["gone.txt"])
        #expect(tombstone.isDeleted)
        #expect(tombstone.supersedes(try #require(first["gone.txt"])))
    }

    /// A file that comes back after a deletion goes after the tombstone even
    /// when its modification time is older, as a restored file's is.
    @Test func restoredFileOutranksItsTombstone() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "restored.txt")
        try Data("back".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path(percentEncoded: false))
        let tombstone = FileRecord(path: "restored.txt", kind: .file, isDeleted: true, version: 2_000_000, modified: 2_000_000)

        guard case .scanned(let records) = FileScanner.scan(root: directory.url, kind: .folder, previous: ["restored.txt": tombstone], now: 3_000_000) else {
            Issue.record("scan didn't find the folder")
            return
        }

        let record = try #require(records["restored.txt"])
        #expect(!record.isDeleted)
        #expect(record.supersedes(tombstone))
        #expect(record.modified == 1_000_000)
    }

    /// A missing root is reported as missing, never as every file deleted.
    @Test func missingRootIsNotADeletion() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let previous = ["a.txt": FileRecord(path: "a.txt", kind: .file, version: 1, size: 1, modified: 1, hash: "h")]

        let outcome = FileScanner.scan(root: directory.url.appending(path: "Unmounted"), kind: .folder, previous: previous, now: 2)

        #expect(outcome == .rootMissing)
    }
}
