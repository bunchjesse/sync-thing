import CryptoKit
import Foundation
import Testing
@testable import SyncKit

/// Two or three simulated Macs pulling from each other, as the app's
/// peers do over their tunnels.
struct SyncEngineTests {
    /// A folder added on one Mac appears on the other, at the same place
    /// under its own home folder, with every file and its modification time.
    @Test func addedFolderReachesTheOtherMac() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let modified = Date(timeIntervalSince1970: 1_700_000_000.5)
        try studio.write("hello", to: "Notes/hello.txt", modified: modified)
        try studio.write("nested", to: "Notes/Ideas/idea.md")
        try await studio.engine.addItem(at: studio.url("Notes"))

        let report = try await laptop.pull(from: studio)

        #expect(report.downloaded == 2)
        #expect(laptop.read("Notes/hello.txt") == "hello")
        #expect(laptop.read("Notes/Ideas/idea.md") == "nested")
        #expect(try laptop.modified("Notes/hello.txt") == modified)
        #expect(await laptop.engine.activeItems().map(\.id) == ["~/Notes"])
    }

    /// A Mac that pulls again with nothing new does nothing, and a file it
    /// downloaded doesn't look changed to its own scan, so the two Macs
    /// don't send it back and forth.
    @Test func syncedFilesSettle() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("hello", to: "Notes/hello.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        #expect(await laptop.engine.rescanAll() == false)
        #expect(try await laptop.pull(from: studio) == SyncReport())
        #expect(try await studio.pull(from: laptop) == SyncReport())
    }

    /// An edit, a new file, and a deletion on either Mac reach the other.
    @Test func changesFlowBothWays() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("v1", to: "Notes/a.txt")
        try studio.write("bye", to: "Notes/b.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try laptop.write("v2", to: "Notes/a.txt", modified: .now.addingTimeInterval(5))
        try laptop.write("new", to: "Notes/c.txt")
        try FileManager.default.removeItem(at: laptop.url("Notes/b.txt"))
        await laptop.engine.rescanAll()
        let report = try await studio.pull(from: laptop)

        #expect(report.downloaded == 2)
        #expect(report.deleted == 1)
        #expect(studio.read("Notes/a.txt") == "v2")
        #expect(studio.read("Notes/c.txt") == "new")
        #expect(studio.read("Notes/b.txt") == nil)
    }

    /// When both Macs changed a file before syncing, the newer edit wins on
    /// both, whichever Mac pulls first, and the older one goes to the Trash
    /// of the Mac that made it.
    @Test func newestEditWins() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("original", to: "Notes/a.txt", modified: ago(60))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try studio.write("older edit", to: "Notes/a.txt", modified: ago(30))
        try laptop.write("newer edit", to: "Notes/a.txt", modified: ago(10))
        await studio.engine.rescanAll()
        await laptop.engine.rescanAll()
        try await laptop.pull(from: studio)
        try await studio.pull(from: laptop)

        #expect(studio.read("Notes/a.txt") == "newer edit")
        #expect(laptop.read("Notes/a.txt") == "newer edit")
        #expect(studio.trash.all == ["older edit"])
        #expect(laptop.trash.all.isEmpty)
    }

    /// A file changed on this Mac since its last scan is never overwritten
    /// by a pull; the next scan picks it up and the newer copy wins.
    @Test func unscannedLocalEditIsNotOverwritten() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("original", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try studio.write("studio edit", to: "Notes/a.txt", modified: .now.addingTimeInterval(10))
        await studio.engine.rescanAll()
        try laptop.write("laptop edit", to: "Notes/a.txt", modified: .now.addingTimeInterval(20))
        try await laptop.pull(from: studio)

        #expect(laptop.read("Notes/a.txt") == "laptop edit")
    }

    /// Changes travel through a Mac in the middle, so every Mac converges
    /// even when two of them never talk directly.
    @Test func changesTravelThroughAThirdMac() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let mini = try TestMac(named: "mini", in: directory)
        try studio.write("hello", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))

        try await laptop.pull(from: studio)
        try await mini.pull(from: laptop)

        #expect(mini.read("Notes/a.txt") == "hello")
    }

    /// A single file can be synced on its own.
    @Test func singleFileSyncs() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("export PATH", to: ".zshrc")
        try await studio.engine.addItem(at: studio.url(".zshrc"))
        try await laptop.pull(from: studio)

        try laptop.write("export PATH=new", to: ".zshrc", modified: .now.addingTimeInterval(5))
        await laptop.engine.rescanAll()
        try await studio.pull(from: laptop)

        #expect(laptop.read(".zshrc") == "export PATH=new")
        #expect(studio.read(".zshrc") == "export PATH=new")
    }

    /// Removing an item on one Mac stops it syncing everywhere, and leaves
    /// its files in place.
    @Test func removedItemStopsEverywhereAndKeepsFiles() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("hello", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        await studio.engine.removeItem(id: "~/Notes")
        try studio.write("after", to: "Notes/b.txt")
        try await laptop.pull(from: studio)

        #expect(await laptop.engine.activeItems().isEmpty)
        #expect(laptop.read("Notes/a.txt") == "hello")
        #expect(laptop.read("Notes/b.txt") == nil)
    }

    /// When an item's folder goes missing on a Mac — an unmounted drive — it
    /// pauses there instead of deleting the files on every other Mac.
    @Test func missingFolderPausesInsteadOfDeleting() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("hello", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try FileManager.default.moveItem(at: laptop.url("Notes"), to: laptop.url("Elsewhere"))
        await laptop.engine.rescanAll()
        let report = try await studio.pull(from: laptop)

        #expect(await laptop.engine.isMissing("~/Notes"))
        #expect(report == SyncReport())
        #expect(studio.read("Notes/a.txt") == "hello")
    }

    /// A Mac that joins with older copies of files keeps the newer ones,
    /// wherever they are, and gains the files it didn't have.
    @Test func joiningMacKeepsTheNewerCopies() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try studio.write("studio is newer", to: "Notes/a.txt", modified: past.addingTimeInterval(100))
        try studio.write("only on studio", to: "Notes/b.txt")
        try laptop.write("laptop is older", to: "Notes/a.txt", modified: past)
        try laptop.write("only on laptop", to: "Notes/c.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.engine.addItem(at: laptop.url("Notes"))

        try await laptop.pull(from: studio)
        try await studio.pull(from: laptop)

        for mac in [studio, laptop] {
            #expect(mac.read("Notes/a.txt") == "studio is newer")
            #expect(mac.read("Notes/b.txt") == "only on studio")
            #expect(mac.read("Notes/c.txt") == "only on laptop")
        }
        #expect(laptop.trash.all == ["laptop is older"])
        #expect(studio.trash.all.isEmpty)
    }

    /// Peers can only name paths inside an item; anything that tries to
    /// climb out is ignored.
    @Test func peerPathsCannotEscapeTheItem() {
        let folder = SyncItem(id: "~/Notes", kind: .folder, version: 1)
        let file = SyncItem(id: "~/.zshrc", kind: .file, version: 1)

        #expect(SyncEngine.isSafe(path: "a/b.txt", in: folder))
        #expect(!SyncEngine.isSafe(path: "../secrets", in: folder))
        #expect(!SyncEngine.isSafe(path: "a/../../b", in: folder))
        #expect(!SyncEngine.isSafe(path: "/etc/passwd", in: folder))
        #expect(!SyncEngine.isSafe(path: "", in: folder))
        #expect(SyncEngine.isSafe(path: "", in: file))
        #expect(!SyncEngine.isSafe(path: "x", in: file))
        #expect(!SyncEngine.isSafeItemID("~/../etc"))
        #expect(!SyncEngine.isSafeItemID("relative/path"))
        #expect(SyncEngine.isSafeItemID("/Volumes/Data/Photos"))
    }

    /// Adding a folder inside one already synced, or around one, is refused.
    @Test func overlappingItemsAreRefused() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("x", to: "Projects/App/main.swift")
        try await studio.engine.addItem(at: studio.url("Projects/App"))

        await #expect(throws: SyncError.containsSyncedItem(child: "~/Projects/App")) {
            try await studio.engine.addItem(at: studio.url("Projects"))
        }
        try studio.write("y", to: "Projects/App/Sources/a.swift")
        await #expect(throws: SyncError.insideSyncedItem(parent: "~/Projects/App")) {
            try await studio.engine.addItem(at: studio.url("Projects/App/Sources"))
        }
        await #expect(throws: SyncError.tooBroad("~")) {
            try await studio.engine.addItem(at: studio.home)
        }
    }

    /// State survives a relaunch: a restarted engine knows its items and
    /// indexes, so a file deleted while it was quit is a deletion.
    @Test func stateSurvivesARelaunch() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("hello", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try FileManager.default.removeItem(at: studio.url("Notes/a.txt"))
        let relaunched = try TestMac(named: "studio", in: directory)
        await relaunched.engine.rescanAll()
        try await laptop.pull(from: relaunched)

        #expect(laptop.read("Notes/a.txt") == nil)
    }

    /// A pull never writes through a symbolic link inside an item, even
    /// when the peer has a real folder where this Mac has a link — the
    /// file would land outside the item.
    @Test func pullsNeverWriteThroughSymlinkedFolders() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("x", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try FileManager.default.createDirectory(at: laptop.url("Outside"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: laptop.url("Notes/Linked"), withDestinationURL: laptop.url("Outside"))
        await laptop.engine.rescanAll()
        try studio.write("escape", to: "Notes/Linked/escape.txt")
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.failed >= 1)
        #expect(laptop.read("Outside/escape.txt") == nil)
    }

    /// A peer's files never reach outside an item through a symbolic link
    /// on the serving Mac, even when its index still lists the path.
    @Test func servingNeverFollowsSymlinks() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("x", to: "Notes/a.txt")
        try studio.write("secret", to: "secret.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))

        try FileManager.default.removeItem(at: studio.url("Notes/a.txt"))
        try FileManager.default.createSymbolicLink(at: studio.url("Notes/a.txt"), withDestinationURL: studio.url("secret.txt"))

        #expect(await studio.engine.servableFile(itemID: "~/Notes", path: "a.txt") == nil)
    }

    /// Records with impossible change times — far in the future or
    /// negative — are ignored, so a broken peer can't win every conflict.
    @Test func implausibleRecordsAreIgnored() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("mine", to: "Notes/a.txt")
        try laptop.write("mine too", to: "Notes/b.txt")
        try await laptop.engine.addItem(at: laptop.url("Notes"))
        let now = Date().syncTimestamp
        let peer = FixedPeer(
            items: [SyncItem(id: "~/Notes", kind: .folder, version: 1)],
            records: [
                fileRecord("a.txt", "theirs", changed: .max),
                fileRecord("b.txt", "theirs", changed: .min),
                fileRecord("c.txt", "theirs", changed: now + SyncEngine.maximumClockSkew + 60_000),
            ],
            contents: ["a.txt": "theirs", "b.txt": "theirs", "c.txt": "theirs"]
        )

        let report = try await laptop.engine.pull(from: peer)

        #expect(report == SyncReport())
        #expect(laptop.tree("Notes") == ["a.txt": "mine", "b.txt": "mine too"])
        #expect(await laptop.engine.rescanAll() == false)
    }

    /// A Mac pulling again gets only the records that changed since its
    /// last pull, and none when nothing did.
    @Test func laterPullsGetOnlyChanges() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        for index in 0..<5 {
            try studio.write("\(index)", to: "Notes/\(index).txt")
        }
        try await studio.engine.addItem(at: studio.url("Notes"))
        let peer = RecordingPeer(engine: studio.engine)

        _ = try await laptop.engine.pull(from: peer)
        try studio.write("edited", to: "Notes/2.txt")
        try studio.remove("Notes/4.txt")
        await studio.engine.rescanAll()
        let report = try await laptop.engine.pull(from: peer)
        _ = try await laptop.engine.pull(from: peer)

        let batches = peer.batches
        #expect(batches.count == 3)
        #expect(batches[0].isComplete && batches[0].records.count == 5)
        #expect(!batches[1].isComplete && batches[1].records.map(\.path) == ["2.txt", "4.txt"])
        #expect(!batches[2].isComplete && batches[2].records.isEmpty)
        #expect(report.downloaded == 1 && report.deleted == 1)
        #expect(laptop.tree("Notes") == ["0.txt": "0", "1.txt": "1", "2.txt": "edited", "3.txt": "3"])
    }

    /// A Mac that relaunched starts its index afresh, so its peers' next
    /// pulls get all of it, and nothing they had goes missing.
    @Test func relaunchedPeerSendsItsWholeIndex() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        _ = try await laptop.engine.pull(from: RecordingPeer(engine: studio.engine))

        let relaunched = try TestMac(named: "studio", in: directory)
        try relaunched.write("b", to: "Notes/b.txt")
        await relaunched.engine.rescanAll()
        let peer = RecordingPeer(engine: relaunched.engine)
        let report = try await laptop.engine.pull(from: peer)

        #expect(peer.batches.first?.isComplete == true)
        #expect(report.downloaded == 1)
        #expect(laptop.tree("Notes") == ["a.txt": "a", "b.txt": "b"])
    }

    /// A download that failed is tried again on the next pull, though the
    /// peer's record didn't change and so isn't sent again: the pull plans
    /// against the peer's whole index as last seen.
    @Test func failedDownloadIsRetriedFromTheLastIndex() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        let failing = FaultyPeer(base: EnginePeer(engine: studio.engine)) { _ in throw URLError(.badServerResponse) }

        let failed = try await laptop.engine.pull(from: failing)
        let retried = try await laptop.pull(from: studio)

        #expect(failed.failed == 1)
        #expect(retried.downloaded == 1)
        #expect(laptop.read("Notes/a.txt") == "a")
    }

    /// A peer's edit that lost to this Mac's concurrent edit still beats
    /// this Mac's later deletion, which never saw it. The peer's record
    /// isn't sent again, so the pull plans from its whole index as last
    /// seen.
    @Test func deletionDoesNotBeatAConcurrentEditItNeverSaw() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("original", to: "Notes/a.txt", modified: ago(100))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try studio.write("studio's", to: "Notes/a.txt", modified: ago(30))
        await studio.engine.rescanAll()
        try laptop.write("laptop's", to: "Notes/a.txt", modified: ago(10))
        await laptop.engine.rescanAll()
        let peer = RecordingPeer(engine: studio.engine)
        let lost = try await laptop.engine.pull(from: peer)
        try laptop.remove("Notes/a.txt")
        await laptop.engine.rescanAll()
        let back = try await laptop.engine.pull(from: peer)
        try await studio.pull(from: laptop)

        #expect(lost == SyncReport())
        #expect(peer.batches.last?.isComplete == false && peer.batches.last?.records.isEmpty == true)
        #expect(back.downloaded == 1)
        for mac in [studio, laptop] {
            #expect(mac.read("Notes/a.txt") == "studio's")
        }
    }

    /// A tombstone pruned from a Mac's index after its lifetime starts the
    /// index afresh, so a peer pulling changes learns the path is gone
    /// from a whole index rather than never hearing of it.
    @Test func prunedTombstoneStartsANewIndex() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        let store = try SyncStore(directory: directory.url.appending(path: "studio-state"))
        var index = try #require(store.loadIndex(itemID: "~/Notes"))
        let expired = Date().syncTimestamp - FileScanner.tombstoneLifetime - 60_000
        index["old.txt"] = FileRecord(
            path: "old.txt", kind: .file, isDeleted: true, version: VersionVector(["studio": expired]), changed: expired, modified: expired
        )
        try store.save(index: index, itemID: "~/Notes")
        let relaunched = try TestMac(named: "studio", in: directory)
        let peer = RecordingPeer(engine: relaunched.engine)
        _ = try await laptop.engine.pull(from: peer)
        let before = try #require(peer.batches.last)
        #expect(before.records.contains { $0.path == "old.txt" })

        try relaunched.write("b", to: "Notes/b.txt")
        await relaunched.engine.rescanAll()
        _ = try await laptop.engine.pull(from: peer)

        let after = try #require(peer.batches.last)
        #expect(after.isComplete)
        #expect(after.position.index != before.position.index)
        #expect(!after.records.contains { $0.path == "old.txt" })
        #expect(laptop.read("Notes/b.txt") == "b")
    }

    /// A peer's item list can't add an item this Mac's user couldn't: one
    /// overlapping an item already synced, the home folder by its absolute
    /// path, or a non-canonical spelling of an existing item.
    @Test func peerItemsFollowTheSameRules() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("x", to: "Notes/a.txt")
        try await laptop.engine.addItem(at: laptop.url("Notes"))
        let version = Date().syncTimestamp
        let peer = FixedPeer(items: [
            SyncItem(id: "~/Notes/Sub", kind: .folder, version: version),
            SyncItem(id: laptop.home.path(percentEncoded: false), kind: .folder, version: version),
            SyncItem(id: "~/Notes/", kind: .folder, version: version),
            SyncItem(id: "~//Notes", kind: .folder, version: version),
        ])

        _ = try await laptop.engine.pull(from: peer)

        #expect(await laptop.engine.activeItems().map(\.id) == ["~/Notes"])
    }

    /// A folder that can't be listed keeps its records, so a permission
    /// change on one Mac never deletes the files on the others.
    @Test func unreadableFolderIsNotADeletion() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("x", to: "Notes/Private/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        let locked = studio.url("Notes/Private").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.deleted == 0)
        #expect(laptop.read("Notes/Private/a.txt") == "x")
    }

    /// The recent files are the newest live files across every item, a
    /// pulled one included, newest first and no more than asked for;
    /// folders, deletions, and paused items are left out.
    @Test func recentFilesAreTheNewestAcrossItems() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let (pulled, zshrc, old) = (ago(100), ago(300), ago(500))
        try studio.write("old", to: "Notes/old.txt", modified: old)
        try studio.write("gone", to: "Notes/gone.txt", modified: ago(10))
        try studio.write("export PATH", to: ".zshrc", modified: zshrc)
        try studio.write("paused", to: "Drive/paused.txt", modified: ago(5))
        try FileManager.default.createDirectory(at: studio.url("Notes/Empty"), withIntermediateDirectories: true)
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await studio.engine.addItem(at: studio.url(".zshrc"))
        try await studio.engine.addItem(at: studio.url("Drive"))
        try await laptop.pull(from: studio)
        try laptop.write("from laptop", to: "Notes/pulled.txt", modified: pulled)
        await laptop.engine.rescanAll()
        try await studio.pull(from: laptop)

        try studio.remove("Notes/gone.txt")
        try FileManager.default.moveItem(at: studio.url("Drive"), to: studio.url("Unmounted"))
        await studio.engine.rescanAll()
        let recent = await studio.engine.recentFiles(limit: 10)
        let newest = await studio.engine.recentFiles(limit: 2)

        #expect(recent == [
            RecentFile(url: studio.url("Notes/pulled.txt"), changed: pulled),
            RecentFile(url: studio.url(".zshrc"), changed: zshrc),
            RecentFile(url: studio.url("Notes/old.txt"), changed: old),
        ])
        #expect(newest == Array(recent.prefix(2)))
    }

    /// A recent file whose folder was replaced by a link keeps its record,
    /// but isn't listed, so the menu can't open what the link leads to.
    @Test func recentFilesSkipPathsThroughLinks() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let plain = ago(200)
        try studio.write("plain", to: "Notes/plain.txt", modified: plain)
        try studio.write("inside", to: "Notes/Sub/inside.txt", modified: ago(100))
        try studio.write("elsewhere", to: "Elsewhere/inside.txt", modified: ago(50))
        try await studio.engine.addItem(at: studio.url("Notes"))

        try FileManager.default.removeItem(at: studio.url("Notes/Sub"))
        try FileManager.default.createSymbolicLink(at: studio.url("Notes/Sub"), withDestinationURL: studio.url("Elsewhere"))
        await studio.engine.rescanAll()

        #expect(await studio.engine.fileCount("~/Notes") == 2)
        #expect(await studio.engine.recentFiles(limit: 10) == [RecentFile(url: studio.url("Notes/plain.txt"), changed: plain)])
    }
}
