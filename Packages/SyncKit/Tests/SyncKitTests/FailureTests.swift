import Foundation
import Testing
@testable import SyncKit

/// What happens when things go wrong: failed and interrupted downloads,
/// damaged state, and roots that come and go.
struct FailureTests {
    /// A download that fails on its own is counted and retried by the next
    /// pull, and the rest of the pull goes ahead.
    @Test func failedDownloadIsRetried() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt")
        try studio.write("b", to: "Notes/b.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        let peer = FaultyPeer(base: EnginePeer(engine: studio.engine), beforeDownload: { path in
            if path == "b.txt" { throw URLError(.badServerResponse) }
        })

        let first = try await laptop.engine.pull(from: peer)
        #expect(first.downloaded == 1)
        #expect(first.failed == 1)
        #expect(laptop.read("Notes/b.txt") == nil)

        let second = try await laptop.pull(from: studio)
        #expect(second.downloaded == 1)
        #expect(laptop.read("Notes/b.txt") == "b")
    }

    /// A file that changes on the peer while it downloads isn't placed;
    /// the copy this Mac had stays until the next pull brings the new one.
    @Test func fileChangedMidDownloadIsNotPlaced() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("v1", to: "Notes/a.txt", modified: ago(1000))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)
        try studio.write("v2", to: "Notes/a.txt", modified: ago(10))
        await studio.engine.rescanAll()

        let peer = FaultyPeer(base: EnginePeer(engine: studio.engine), altered: ["a.txt"])
        let report = try await laptop.engine.pull(from: peer)

        #expect(report.failed == 1)
        #expect(laptop.read("Notes/a.txt") == "v1")
        try await laptop.pull(from: studio)
        #expect(laptop.read("Notes/a.txt") == "v2")
    }

    /// A pull cancelled partway — as when the app quits — stops before the
    /// next path, keeps what it placed, and leaves the index saved.
    @Test func cancelledPullKeepsWhatItPlaced() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        for index in 0..<4 {
            try studio.write("\(index)", to: "Notes/\(index).txt")
        }
        try await studio.engine.addItem(at: studio.url("Notes"))
        let peer = FaultyPeer(base: EnginePeer(engine: studio.engine), beforeDownload: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })

        await #expect(throws: CancellationError.self) {
            try await laptop.engine.pull(from: peer)
        }

        #expect(laptop.tree("Notes").count == 1)
        let relaunched = try TestMac(named: "laptop", in: directory)
        #expect(await relaunched.engine.fileCount("~/Notes") == 1)
    }

    /// A lost item list is set aside, and the items come back from a peer
    /// with this Mac's saved indexes, so a file deleted here before the
    /// loss isn't downloaded back — and the deletion still reaches the peer.
    @Test func corruptItemListRecoversWithoutResurrecting() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt", modified: ago(1000))
        try studio.write("b", to: "Notes/b.txt", modified: ago(1000))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)
        try studio.remove("Notes/b.txt")
        await studio.engine.rescanAll()

        let state = directory.url.appending(path: "studio-state")
        try Data("not json".utf8).write(to: state.appending(path: "items.json"))
        let relaunched = try TestMac(named: "studio", in: directory)
        #expect(await relaunched.engine.activeItems().isEmpty)
        #expect(FileManager.default.fileExists(atPath: state.appending(path: "items.json.corrupt").path(percentEncoded: false)))

        let report = try await relaunched.pull(from: laptop)
        try await laptop.pull(from: relaunched)

        #expect(report.downloaded == 0)
        #expect(relaunched.read("Notes/b.txt") == nil)
        #expect(laptop.read("Notes/b.txt") == nil)
    }

    /// A damaged index is set aside and the item rescanned from scratch,
    /// which deletes nothing anywhere.
    @Test func corruptIndexRescansWithoutDeleting() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        let indexes = directory.url.appending(path: "studio-state/indexes")
        for name in try FileManager.default.contentsOfDirectory(atPath: indexes.path(percentEncoded: false)) {
            try Data("{".utf8).write(to: indexes.appending(path: name))
        }
        let relaunched = try TestMac(named: "studio", in: directory)
        await relaunched.engine.rescanAll()
        let report = try await laptop.pull(from: relaunched)

        #expect(report == SyncReport())
        #expect(laptop.read("Notes/a.txt") == "a")
        #expect(await relaunched.engine.fileCount("~/Notes") == 1)
    }

    /// A Mac whose state can't be saved keeps syncing from memory.
    @Test func unwritableStateStillSyncs() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        let state = directory.url.appending(path: "laptop-state")
        let path = state.path(percentEncoded: false)
        let indexes = state.appending(path: "indexes").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: indexes)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: indexes)
        }

        let report = try await laptop.pull(from: studio)

        #expect(report.downloaded == 1)
        #expect(laptop.read("Notes/a.txt") == "a")
    }

    /// An item whose folder goes missing pauses, nothing is written into or
    /// recreated at its place meanwhile, and once the folder is back it
    /// resumes, catching up on what changed elsewhere without deleting
    /// anything.
    @Test func missingRootPausesThenResumes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt", modified: ago(1000))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)
        let events = await EventLog(engine: laptop.engine)

        try FileManager.default.moveItem(at: laptop.url("Notes"), to: laptop.url("Unmounted"))
        await laptop.engine.rescanAll()
        try studio.write("b", to: "Notes/b.txt")
        await studio.engine.rescanAll()
        #expect(try await laptop.pull(from: studio) == SyncReport())
        #expect(!laptop.exists("Notes"))

        try FileManager.default.moveItem(at: laptop.url("Unmounted"), to: laptop.url("Notes"))
        await laptop.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.downloaded == 1)
        #expect(report.deleted == 0)
        #expect(laptop.tree("Notes") == ["a.txt": "a", "b.txt": "b"])
        #expect(events.all.filter { $0 == .availabilityChanged(itemID: "~/Notes") }.count == 2)
    }

    /// Emptying a folder on purpose — every file deleted, the folder kept —
    /// is a deletion like any other, and reaches the other Macs.
    @Test func emptiedFolderDeletesEverywhere() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt")
        try studio.write("b", to: "Notes/b.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try studio.remove("Notes/a.txt")
        try studio.remove("Notes/b.txt")
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.deleted == 2)
        #expect(laptop.tree("Notes").isEmpty)
        #expect(laptop.exists("Notes"))
    }

    /// Each change is reported once, and a scan that finds nothing new
    /// reports nothing, so peers aren't told to pull for no reason.
    @Test func eventsReportEachChangeOnce() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let studioEvents = await EventLog(engine: studio.engine)
        let laptopEvents = await EventLog(engine: laptop.engine)
        try studio.write("a", to: "Notes/a.txt")

        try await studio.engine.addItem(at: studio.url("Notes"))
        #expect(studioEvents.all == [.itemsChanged, .filesChanged(itemID: "~/Notes")])

        try await laptop.pull(from: studio)
        #expect(laptopEvents.all.first == .itemsChanged)
        #expect(laptopEvents.all.dropFirst().allSatisfy { $0 == .filesChanged(itemID: "~/Notes") })

        studioEvents.clear()
        laptopEvents.clear()
        await studio.engine.rescanAll()
        try await laptop.pull(from: studio)
        #expect(studioEvents.all.isEmpty)
        #expect(laptopEvents.all.isEmpty)

        await studio.engine.removeItem(id: "~/Notes")
        #expect(studioEvents.all == [.itemsChanged])
    }
}
