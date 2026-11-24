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
        #expect(Date(syncTimestamp: -315_619_200_000).syncTimestamp == -315_619_200_000)
    }

    /// A trailing slash, on the path or on the home folder, doesn't change
    /// the portable path, and odd names survive the round trip.
    @Test func portablePathsIgnoreTrailingSlashes() {
        let locations = SyncLocations(home: URL(filePath: "/Users/alice/"))

        #expect(locations.portablePath(for: URL(filePath: "/Users/alice/Notes/")) == "~/Notes")
        #expect(locations.portablePath(for: URL(filePath: "/Users/alice/")) == "~")
        let odd = "~/A b/c%d/é 🎉"
        #expect(locations.portablePath(for: locations.url(forPortablePath: odd)) == odd)
    }

    /// Every spelling of a place on disk — through a link, in another case,
    /// through `/var` or `/private/var` — has one portable path.
    @Test func portablePathsFollowTheDisk() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let locations = SyncLocations(home: directory.url)
        try FileManager.default.createDirectory(at: directory.url.appending(path: "Notes"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.url.appending(path: "Link"), withDestinationURL: directory.url.appending(path: "Notes"))
        let privateVar = URL(filePath: SyncLocations.realPath(directory.url)).appending(path: "Notes")

        #expect(locations.portablePath(for: directory.url.appending(path: "notes")) == "~/Notes")
        #expect(locations.portablePath(for: directory.url.appending(path: "Link")) == "~/Notes")
        #expect(locations.portablePath(for: privateVar) == "~/Notes")
        #expect(locations.portablePath(for: directory.url.appending(path: "Notes/Not Yet")) == "~/Notes/Not Yet")
    }
}

struct SafetyCheckTests {
    /// Only canonical item IDs are accepted from a peer: under `~/` or `/`,
    /// with no empty, `.`, or `..` components, no trailing slash, and no
    /// control characters.
    @Test(arguments: [
        ("~/Notes", true), ("/Volumes/Data/Photos", true), ("~/.zshrc", true),
        ("~", false), ("/", false), ("~/", false), ("~user/Notes", false), ("~/a//b", false),
        ("~/a/", false), ("~/./a", false), ("~/a/../b", false), ("", false), ("Notes", false),
        ("~/a\u{0}b", false), ("~/a\u{7}", false),
    ])
    func itemIDs(id: String, isSafe: Bool) {
        #expect(SyncEngine.isSafeItemID(id) == isSafe)
    }

    /// Paths within an item are relative and canonical, with no ignored
    /// names or control characters other than tab and newline, which a
    /// name can hold.
    @Test(arguments: [
        ("a.txt", true), ("Sub/a.txt", true), ("new\nline.txt", true), ("tab\t.txt", true),
        ("", false), ("/a", false), ("a/", false), ("a//b", false), ("./a", false), ("../a", false),
        ("Sub/.DS_Store", false), ("victim\u{0}", false), ("a\u{1b}b", false),
    ])
    func paths(path: String, isSafe: Bool) {
        #expect(SyncEngine.isSafe(path: path, in: SyncItem(id: "~/Notes", kind: .folder, version: 1)) == isSafe)
    }

    /// A path is free of links only when nothing between the root and it —
    /// and, when asked, the path itself, even when it is the root — is a
    /// symbolic link. Paths that don't exist yet pass; paths outside the
    /// root don't.
    @Test func hasNoLinks() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appending(path: "Root")
        try FileManager.default.createDirectory(at: root.appending(path: "Real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Link"), withDestinationURL: directory.url)
        try FileManager.default.createSymbolicLink(at: directory.url.appending(path: "RootLink"), withDestinationURL: root)
        let rootLink = directory.url.appending(path: "RootLink")

        #expect(SyncEngine.hasNoLinks(below: root, to: root.appending(path: "Real/new.txt"), includingTarget: true))
        #expect(SyncEngine.hasNoLinks(below: root, to: root.appending(path: "Missing/deeper/new.txt"), includingTarget: true))
        #expect(!SyncEngine.hasNoLinks(below: root, to: root.appending(path: "Link/x.txt"), includingTarget: false))
        #expect(!SyncEngine.hasNoLinks(below: root, to: root.appending(path: "Link"), includingTarget: true))
        #expect(SyncEngine.hasNoLinks(below: root, to: root.appending(path: "Link"), includingTarget: false))
        #expect(!SyncEngine.hasNoLinks(below: rootLink, to: rootLink, includingTarget: true))
        #expect(SyncEngine.hasNoLinks(below: rootLink, to: rootLink, includingTarget: false))
        #expect(!SyncEngine.hasNoLinks(below: root, to: directory.url.appending(path: "Elsewhere"), includingTarget: true))
    }

    /// Timestamps are plausible from 1970 to a week past now, inclusive,
    /// and a record's size can't be negative. Its modification time can be
    /// anything.
    @Test func plausibility() {
        let now: SyncTimestamp = 1_800_000_000_000
        let limit = now + SyncEngine.maximumClockSkew

        #expect(SyncEngine.isPlausible(0, now: now))
        #expect(SyncEngine.isPlausible(limit, now: now))
        #expect(!SyncEngine.isPlausible(limit + 1, now: now))
        #expect(!SyncEngine.isPlausible(-1, now: now))
        #expect(!SyncEngine.isPlausible(.max, now: now))
        #expect(SyncEngine.isPlausible(FileRecord(path: "a", kind: .file, version: now, modified: -1_000), now: now))
        #expect(!SyncEngine.isPlausible(FileRecord(path: "a", kind: .file, version: now, size: -1, modified: now), now: now))
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

    /// A file and a directory tied on version resolve the same way on both
    /// Macs, and a record never supersedes itself.
    @Test func fileAndDirectoryTiesAreDeterministic() {
        let file = FileRecord(path: "a", kind: .file, version: 5, modified: 5, hash: "x")
        let directory = FileRecord(path: "a", kind: .directory, version: 5, modified: 5)

        #expect(file.supersedes(directory) != directory.supersedes(file))
        #expect(!file.supersedes(file))
        #expect(!directory.supersedes(directory))
    }

    /// Records describe the same thing when both are deletions, both the
    /// same directory, or files with the same hash — whatever their
    /// versions.
    @Test func sameContent() {
        let file = FileRecord(path: "a", kind: .file, version: 1, modified: 1, hash: "x")
        var later = file
        later.version = 9
        later.modified = 9
        let other = FileRecord(path: "a", kind: .file, version: 1, modified: 1, hash: "y")
        let directory = FileRecord(path: "a", kind: .directory, version: 1, modified: 1)

        #expect(file.hasSameContent(as: later))
        #expect(!file.hasSameContent(as: other))
        #expect(!file.hasSameContent(as: directory))
        #expect(directory.hasSameContent(as: FileRecord(path: "a", kind: .directory, version: 7, modified: 7)))
        #expect(file.deleted(at: 3).hasSameContent(as: directory.deleted(at: 4)))
        #expect(!file.hasSameContent(as: file.deleted(at: 3)))
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

    /// Scans `root` as a folder and returns its records, recording an issue
    /// when the root is missing.
    private func scan(_ root: URL, previous: [String: FileRecord] = [:], now: SyncTimestamp = Date().syncTimestamp) -> [String: FileRecord] {
        guard case .scanned(let records) = FileScanner.scan(root: root, kind: .folder, previous: previous, now: now) else {
            Issue.record("scan didn't find the folder")
            return [:]
        }
        return records
    }

    /// A tombstone is kept until it's 90 days old, then dropped.
    @Test func tombstonesArePrunedAfterTheirLifetime() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let now: SyncTimestamp = 1_800_000_000_000
        let young = FileRecord(path: "young", kind: .file, isDeleted: true, version: now - FileScanner.tombstoneLifetime + 1, modified: 0)
        let old = FileRecord(path: "old", kind: .file, isDeleted: true, version: now - FileScanner.tombstoneLifetime, modified: 0)

        let records = scan(directory.url, previous: ["young": young, "old": old], now: now)

        #expect(records == ["young": young])
    }

    /// A file whose modification time changed but whose contents didn't
    /// keeps its version, with the new time recorded.
    @Test func touchedFileKeepsItsVersion() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "a.txt")
        try Data("same".utf8).write(to: file)
        let first = scan(directory.url)
        let touched = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: file.path(percentEncoded: false))

        let second = scan(directory.url, previous: first)

        #expect(second["a.txt"]?.version == first["a.txt"]?.version)
        #expect(second["a.txt"]?.modified == touched.syncTimestamp)
    }

    /// A file that can't be read keeps its record, and one that can't be
    /// read and has no record gets none, rather than a guess.
    @Test func unreadableFileKeepsItsRecord() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let known = directory.url.appending(path: "known.txt")
        let unknown = directory.url.appending(path: "unknown.txt")
        try Data("known".utf8).write(to: known)
        let first = scan(directory.url)
        try Data("changed".utf8).write(to: known)
        try Data("unknown".utf8).write(to: unknown)
        for url in [known, unknown] {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path(percentEncoded: false))
        }
        defer {
            for url in [known, unknown] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false))
            }
        }

        let second = scan(directory.url, previous: first)

        #expect(second == first)
    }

    /// A file or folder replaced by a symbolic link keeps its records, and
    /// so does everything under the folder: links aren't synced, and the
    /// link isn't a deletion.
    @Test func pathReplacedByALinkKeepsItsRecords() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appending(path: "Notes")
        try FileManager.default.createDirectory(at: root.appending(path: "Sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "a.txt"))
        try Data("b".utf8).write(to: root.appending(path: "Sub/b.txt"))
        let first = scan(root)

        try FileManager.default.removeItem(at: root.appending(path: "a.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "a.txt"), withDestinationURL: directory.url)
        try FileManager.default.moveItem(at: root.appending(path: "Sub"), to: directory.url.appending(path: "Sub"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Sub"), withDestinationURL: directory.url.appending(path: "Sub"))
        let second = scan(root, previous: first)

        #expect(second == first)
    }

    /// A deletion is dated by its folder's modification time — when the
    /// folder lost the entry — not by when the scan noticed, and never
    /// later than now.
    @Test func deletionsAreDatedByTheirFolder() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appending(path: "Notes")
        try FileManager.default.createDirectory(at: root.appending(path: "Sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "Sub/a.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: root.appending(path: "Sub/a.txt").path(percentEncoded: false))
        let first = scan(root)

        try FileManager.default.removeItem(at: root.appending(path: "Sub/a.txt"))
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: deletedAt], ofItemAtPath: root.appending(path: "Sub").path(percentEncoded: false))
        let second = scan(root, previous: first, now: 1_800_000_000_000)
        let capped = scan(root, previous: first, now: 1_600_000_000_000)

        #expect(second["Sub/a.txt"]?.isDeleted == true)
        #expect(second["Sub/a.txt"]?.version == deletedAt.syncTimestamp)
        #expect(capped["Sub/a.txt"]?.version == 1_600_000_000_000)
    }

    /// A file stamped in the future gets a version no later than now, so a
    /// later change anywhere can outrank it; its stamp is kept as is.
    @Test func futureFilesAreVersionedNow() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "a.txt")
        try Data("a".utf8).write(to: file)
        let future = Date(timeIntervalSince1970: 4_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: file.path(percentEncoded: false))

        let records = scan(directory.url, now: 1_800_000_000_000)

        #expect(records["a.txt"]?.version == 1_800_000_000_000)
        #expect(records["a.txt"]?.modified == future.syncTimestamp)
    }

    /// A file replaced by a folder, and a folder by a file, get versions
    /// after the records they replace, and what was in the folder becomes
    /// tombstones.
    @Test func swapsBetweenFileAndFolderAreNewVersions() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url
        try Data("file".utf8).write(to: root.appending(path: "a"))
        try FileManager.default.createDirectory(at: root.appending(path: "b"), withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: root.appending(path: "b/inside.txt"))
        let first = scan(root, now: 1_800_000_000_000)

        try FileManager.default.removeItem(at: root.appending(path: "a"))
        try FileManager.default.createDirectory(at: root.appending(path: "a"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: root.appending(path: "b"))
        try Data("now a file".utf8).write(to: root.appending(path: "b"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: root.appending(path: "b").path(percentEncoded: false))
        let second = scan(root, previous: first, now: 1_800_000_000_000)

        let a = try #require(second["a"])
        let b = try #require(second["b"])
        let oldA = try #require(first["a"])
        let oldB = try #require(first["b"])
        #expect(a.kind == .directory && a.supersedes(oldA))
        #expect(b.kind == .file && b.supersedes(oldB))
        #expect(second["b/inside.txt"]?.isDeleted == true)
    }

    /// A single-file item whose file became a folder or a link is paused,
    /// as a missing one is, rather than deleted.
    @Test func singleFileThatIsNoLongerAFileIsMissing() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "config")
        let previous = ["": FileRecord(path: "", kind: .file, version: 1, size: 1, modified: 1, hash: "h")]
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(FileScanner.scan(root: file, kind: .file, previous: previous, now: 2) == .rootMissing)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.url)
        #expect(FileScanner.scan(root: file, kind: .file, previous: previous, now: 2) == .rootMissing)

        try FileManager.default.removeItem(at: file)
        guard case .scanned(let records) = FileScanner.scan(root: file, kind: .file, previous: previous, now: 2) else {
            Issue.record("a deleted file isn't a missing root")
            return
        }
        #expect(records[""]?.isDeleted == true)
    }
}

struct SyncStoreTests {
    /// The item list and indexes survive a round trip; a removed index is
    /// gone; a first launch has nothing.
    @Test func roundTrip() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = try SyncStore(directory: directory.url.appending(path: "state"))
        #expect(store.loadItems().isEmpty)
        #expect(store.loadIndex(itemID: "~/Notes") == nil)

        let items = [SyncItem(id: "~/Notes", kind: .folder, version: 1), SyncItem(id: "~/Old", kind: .folder, version: 2, isRemoved: true)]
        let index = ["a.txt": FileRecord(path: "a.txt", kind: .file, version: 1, size: 1, modified: 1, hash: "h")]
        try store.save(items: items)
        try store.save(index: index, itemID: "~/Notes")

        #expect(store.loadItems() == items)
        #expect(store.loadIndex(itemID: "~/Notes") == index)
        #expect(store.loadIndex(itemID: "~/Other") == nil)
        store.removeIndex(itemID: "~/Notes")
        #expect(store.loadIndex(itemID: "~/Notes") == nil)
    }

    /// A file that doesn't decode is moved aside, not overwritten by the
    /// next save, and a second bad file replaces the first one set aside.
    @Test func corruptFilesAreSetAside() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let state = directory.url.appending(path: "state")
        let store = try SyncStore(directory: state)
        let items = state.appending(path: "items.json")
        let aside = state.appending(path: "items.json.corrupt")

        try Data("first".utf8).write(to: items)
        #expect(store.loadItems().isEmpty)
        try store.save(items: [])
        try Data("second".utf8).write(to: items)
        #expect(store.loadItems().isEmpty)

        #expect(try String(contentsOf: aside, encoding: .utf8) == "second")
    }
}
