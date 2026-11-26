import Foundation
import Testing
@testable import SyncKit

/// Edge-case inputs: empty and odd files and names, sizes, depths, and
/// timestamps.
struct DegenerateInputTests {
    /// Empty files and empty folders, nested or not, sync, and so does
    /// deleting them.
    @Test func emptyFilesAndFoldersSync() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("", to: "Notes/empty.txt")
        try FileManager.default.createDirectory(at: studio.url("Notes/Empty/Nested"), withIntermediateDirectories: true)
        try await studio.engine.addItem(at: studio.url("Notes"))

        try await laptop.pull(from: studio)
        #expect(laptop.tree("Notes") == ["empty.txt": "", "Empty": "/", "Empty/Nested": "/"])

        try studio.remove("Notes/Empty")
        try studio.remove("Notes/empty.txt")
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.deleted == 3)
        #expect(laptop.tree("Notes").isEmpty)
    }

    /// Names with spaces, punctuation that means something in URLs and
    /// shells, a newline, a leading dot, and non-ASCII characters sync.
    @Test(arguments: [
        "with space.txt", "100%.txt", "what?.txt", "#hash.txt", "a+b.txt", "a&b=c.txt", "semi;colon.txt",
        "new\nline.txt", ".hidden", "émoji 🎉.txt", "back\\slash.txt", "colon:name.txt", "trailing.",
    ])
    func oddNamesSync(name: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("contents", to: "Notes/Sub \(name)/\(name)")
        try await studio.engine.addItem(at: studio.url("Notes"))

        let report = try await laptop.pull(from: studio)

        #expect(report.failed == 0)
        #expect(laptop.read("Notes/Sub \(name)/\(name)") == "contents")
    }

    /// Finder's bookkeeping files never sync, a peer can't send one, and a
    /// folder holding nothing else can still be deleted.
    @Test func ignoredNamesNeverSync() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("x", to: "Notes/Folder/a.txt")
        try studio.write("finder", to: "Notes/.DS_Store")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)
        #expect(!laptop.exists("Notes/.DS_Store"))

        try laptop.write("laptop's finder", to: "Notes/Folder/.DS_Store")
        try studio.remove("Notes/Folder")
        await studio.engine.rescanAll()
        try await laptop.pull(from: studio)
        #expect(!laptop.exists("Notes/Folder"))

        let peer = FixedPeer(
            items: [SyncItem(id: "~/Notes", kind: .folder, version: 1)],
            records: [fileRecord(".DS_Store", "evil", changed: ago(1).syncTimestamp), fileRecord("Sub/.localized", "evil", changed: ago(1).syncTimestamp)],
            contents: [".DS_Store": "evil", "Sub/.localized": "evil"]
        )
        #expect(try await laptop.engine.pull(from: peer) == SyncReport())
        #expect(!laptop.exists("Notes/Sub"))
    }

    /// Hundreds of files across many folders all sync, and settle.
    @Test func manyFilesSync() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        for folder in 0..<25 {
            for file in 0..<20 {
                try studio.write("\(folder)-\(file)", to: "Notes/\(folder)/\(file).txt")
            }
        }
        try await studio.engine.addItem(at: studio.url("Notes"))

        let report = try await laptop.pull(from: studio)

        #expect(report.downloaded == 500)
        #expect(await laptop.engine.fileCount("~/Notes") == 500)
        #expect(try await laptop.pull(from: studio) == SyncReport())
    }

    /// A deeply nested file syncs, and deleting its top folder deletes
    /// every folder on the way.
    @Test func deepPathsSync() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let deep = (0..<40).map { "level\($0)" }.joined(separator: "/")
        try studio.write("bottom", to: "Notes/\(deep)/file.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)
        #expect(laptop.read("Notes/\(deep)/file.txt") == "bottom")

        try studio.remove("Notes/level0")
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.deleted == 41)
        #expect(laptop.tree("Notes").isEmpty)
    }

    /// Macs with nothing to sync pull nothing and report nothing.
    @Test func nothingToSync() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let events = await EventLog(engine: laptop.engine)

        #expect(try await laptop.pull(from: studio) == SyncReport())
        #expect(await laptop.engine.rescanAll() == false)
        #expect(events.all.isEmpty)
    }

    /// A file stamped far in the future syncs, keeps its stamp, and doesn't
    /// outrank later changes made anywhere — edits and deletion alike.
    @Test func futureModificationTimeDoesNotFreezeAFile() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let future = Date(syncTimestamp: Date.now.addingTimeInterval(60 * 60 * 24 * 365).syncTimestamp)
        try studio.write("from the future", to: "Notes/a.txt", modified: future)
        try await studio.engine.addItem(at: studio.url("Notes"))

        try await laptop.pull(from: studio)
        #expect(laptop.read("Notes/a.txt") == "from the future")
        #expect(laptop.timestamp("Notes/a.txt") == future.syncTimestamp)

        try laptop.write("fixed", to: "Notes/a.txt")
        await laptop.engine.rescanAll()
        try await studio.pull(from: laptop)
        #expect(studio.read("Notes/a.txt") == "fixed")

        try studio.remove("Notes/a.txt")
        await studio.engine.rescanAll()
        try await laptop.pull(from: studio)
        #expect(laptop.read("Notes/a.txt") == nil)
    }

    /// A file dated before 1970 syncs and keeps its date.
    @Test func modificationTimeBefore1970Syncs() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let ancient = Date(timeIntervalSince1970: -315_619_200)
        try studio.write("old", to: "Notes/old.txt", modified: ancient)
        try await studio.engine.addItem(at: studio.url("Notes"))

        let report = try await laptop.pull(from: studio)

        #expect(report.downloaded == 1)
        #expect(laptop.timestamp("Notes/old.txt") == ancient.syncTimestamp)
        #expect(await laptop.engine.rescanAll() == false)
    }

    /// A peer that lists an item but serves no index for it — it's paused
    /// there — is skipped without changing anything.
    @Test func peerWithoutAnIndexIsSkipped() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("mine", to: "Notes/a.txt")
        try await laptop.engine.addItem(at: laptop.url("Notes"))
        let peer = FixedPeer(items: [SyncItem(id: "~/Notes", kind: .folder, version: 1)], records: nil)

        #expect(try await laptop.engine.pull(from: peer) == SyncReport())
        #expect(laptop.read("Notes/a.txt") == "mine")
    }

    /// Malformed records from a peer — a duplicate path, a file with no
    /// hash, a negative size, a file under a file — change nothing they
    /// shouldn't and don't stop the rest of the pull.
    @Test func malformedRecordsAreContained() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("mine", to: "Notes/a.txt", modified: ago(1000))
        try await laptop.engine.addItem(at: laptop.url("Notes"))
        let version = ago(10).syncTimestamp
        var noHash = fileRecord("nohash.txt", "x", changed: version)
        noHash.hash = nil
        var negative = fileRecord("negative.txt", "x", changed: version)
        negative.size = -1
        let peer = FixedPeer(
            items: [SyncItem(id: "~/Notes", kind: .folder, version: 1)],
            records: [
                fileRecord("dup.txt", "first", changed: version),
                fileRecord("dup.txt", "second", changed: version + 1),
                noHash,
                negative,
                fileRecord("a.txt/under.txt", "x", changed: version),
                fileRecord("good.txt", "good", changed: version),
            ],
            contents: ["dup.txt": "first", "nohash.txt": "x", "negative.txt": "x", "a.txt/under.txt": "x", "good.txt": "good"]
        )

        let report = try await laptop.engine.pull(from: peer)

        #expect(laptop.read("Notes/a.txt") == "mine")
        #expect(laptop.read("Notes/good.txt") == "good")
        #expect(laptop.read("Notes/nohash.txt") == nil)
        #expect(laptop.read("Notes/negative.txt") == nil)
        #expect(report.failed >= 2)
    }

    /// Records whose versions no working Mac could have made — no Macs,
    /// too many, a counter that isn't positive or is near overflowing, a
    /// Mac ID that is empty, too long, or holds a control character — are
    /// ignored, and neither replace this Mac's files nor add any.
    @Test func implausibleVersionsAreIgnored() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("mine", to: "Notes/a.txt", modified: ago(1000))
        try await laptop.engine.addItem(at: laptop.url("Notes"))
        let now = ago(0).syncTimestamp
        let crowd = Dictionary(uniqueKeysWithValues: (0...VersionVector.maximumMacs).map { ("mac\($0)", now) })
        let versions: [[String: Int64]] = [
            [:], crowd, ["peer": 0], ["peer": -1], ["peer": .max], ["laptop": .max - 1, "peer": 1],
            ["": now], [String(repeating: "m", count: 65): now], ["pe\u{0}er": now],
        ]
        let records = versions.enumerated().flatMap { index, counters in
            var replacing = fileRecord("a.txt", "theirs \(index)", changed: now)
            replacing.version = VersionVector(counters)
            var adding = fileRecord("new\(index).txt", "new", changed: now)
            adding.version = VersionVector(counters)
            return [replacing, adding]
        }
        let peer = FixedPeer(
            items: [SyncItem(id: "~/Notes", kind: .folder, version: 1)],
            records: records,
            contents: Dictionary(records.map { ($0.path, "x") }, uniquingKeysWith: { first, _ in first })
        )

        let report = try await laptop.engine.pull(from: peer)

        #expect(report == SyncReport())
        #expect(laptop.tree("Notes") == ["a.txt": "mine"])
    }
}
