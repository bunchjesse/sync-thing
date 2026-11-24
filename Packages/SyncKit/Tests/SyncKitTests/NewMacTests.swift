import Foundation
import Testing
@testable import SyncKit

/// A Mac with no sync state joining Macs that already sync: what it gets,
/// what it keeps, and what it sends back.
struct NewMacTests {
    /// A Mac with nothing gets every item — folders and single files — and
    /// everything in them: files with their modification times, empty
    /// folders, nested folders. It sends nothing back, since it deleted
    /// nothing.
    @Test func emptyMacGetsEverything() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let modified = ago(3600)
        try studio.write("hello", to: "Notes/hello.txt", modified: modified)
        try studio.write("deep", to: "Notes/A/B/C/deep.md")
        try FileManager.default.createDirectory(at: studio.url("Notes/Empty"), withIntermediateDirectories: true)
        try studio.write("export PATH", to: ".zshrc")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await studio.engine.addItem(at: studio.url(".zshrc"))

        let laptop = try TestMac(named: "laptop", in: directory)
        let report = try await laptop.pull(from: studio)

        #expect(report.downloaded == 3)
        #expect(report.deleted == 0)
        #expect(report.failed == 0)
        #expect(await laptop.engine.activeItems().map(\.id) == ["~/.zshrc", "~/Notes"])
        #expect(laptop.tree("Notes") == studio.tree("Notes"))
        #expect(laptop.read(".zshrc") == "export PATH")
        #expect(laptop.timestamp("Notes/hello.txt") == modified.syncTimestamp)
        #expect(await laptop.engine.rescanAll() == false)
        #expect(try await studio.pull(from: laptop) == SyncReport())
    }

    /// A Mac that already has the folder merges with it: a file with the
    /// same contents is adopted without downloading, the newer of two
    /// different copies wins on both Macs, and files only one Mac has reach
    /// the other.
    @Test func macWithExistingCopiesMerges() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("same", to: "Notes/same.txt", modified: ago(100))
        try laptop.write("same", to: "Notes/same.txt", modified: ago(900))
        try studio.write("studio newer", to: "Notes/studio-newer.txt", modified: ago(100))
        try laptop.write("laptop older", to: "Notes/studio-newer.txt", modified: ago(900))
        try studio.write("studio older", to: "Notes/laptop-newer.txt", modified: ago(900))
        try laptop.write("laptop newer", to: "Notes/laptop-newer.txt", modified: ago(100))
        try studio.write("studio only", to: "Notes/studio-only.txt")
        try laptop.write("laptop only", to: "Notes/laptop-only.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))

        let first = try await laptop.pull(from: studio)
        try await studio.pull(from: laptop)

        #expect(first.downloaded == 2)
        #expect(first.deleted == 0)
        for mac in [studio, laptop] {
            #expect(mac.tree("Notes") == [
                "same.txt": "same",
                "studio-newer.txt": "studio newer",
                "laptop-newer.txt": "laptop newer",
                "studio-only.txt": "studio only",
                "laptop-only.txt": "laptop only",
            ])
        }
        #expect(laptop.timestamp("Notes/same.txt") == studio.timestamp("Notes/same.txt"))
        #expect(try await laptop.pull(from: studio) == SyncReport())
        #expect(try await studio.pull(from: laptop) == SyncReport())
    }

    /// A deletion the other Macs remember reaches a joining Mac's older
    /// copy, but a copy changed after the deletion survives and comes back
    /// to them.
    @Test func joiningMacHonorsDeletionsOlderThanItsCopies() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("x", to: "Notes/stale.txt", modified: ago(10_000))
        try studio.write("y", to: "Notes/revived.txt", modified: ago(10_000))
        try studio.write("keep", to: "Notes/keep.txt", modified: ago(10_000))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try studio.remove("Notes/stale.txt")
        try studio.remove("Notes/revived.txt")
        try studio.setModified(ago(1000), of: "Notes")
        await studio.engine.rescanAll()

        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("old copy", to: "Notes/stale.txt", modified: ago(5000))
        try laptop.write("edited since", to: "Notes/revived.txt", modified: ago(100))
        try await laptop.pull(from: studio)
        try await studio.pull(from: laptop)

        #expect(laptop.read("Notes/stale.txt") == nil)
        #expect(laptop.read("Notes/revived.txt") == "edited since")
        #expect(studio.read("Notes/revived.txt") == "edited since")
        #expect(studio.read("Notes/stale.txt") == nil)
    }

    /// An item the other Macs removed before this one joined isn't added,
    /// and its folder isn't created.
    @Test func removedItemsDoNotReachAJoiningMac() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("x", to: "Old/a.txt")
        try await studio.engine.addItem(at: studio.url("Old"))
        await studio.engine.removeItem(id: "~/Old")

        let laptop = try TestMac(named: "laptop", in: directory)
        let report = try await laptop.pull(from: studio)

        #expect(report == SyncReport())
        #expect(await laptop.engine.activeItems().isEmpty)
        #expect(!laptop.exists("Old"))
    }

    /// A joining Mac that has a file where the item's folder belongs leaves
    /// the file alone and pauses the item instead.
    @Test func fileInTheWayPausesTheItem() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("x", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))

        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("not a folder", to: "Notes")
        let report = try await laptop.pull(from: studio)

        #expect(report == SyncReport())
        #expect(await laptop.engine.isMissing("~/Notes"))
        #expect(laptop.read("Notes") == "not a folder")
        #expect(try await studio.pull(from: laptop) == SyncReport())
        #expect(studio.read("Notes/a.txt") == "x")
    }

    /// A first sync cut off partway keeps what arrived, across a relaunch,
    /// and the next pull brings the rest without deleting anything on
    /// either Mac.
    @Test func interruptedFirstSyncResumes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        for index in 0..<5 {
            try studio.write("file \(index)", to: "Notes/\(index).txt")
        }
        try await studio.engine.addItem(at: studio.url("Notes"))

        let laptop = try TestMac(named: "laptop", in: directory)
        let downloads = Counter()
        let flaky = FaultyPeer(base: EnginePeer(engine: studio.engine), beforeDownload: { _ in
            if downloads.increment() == 3 { throw URLError(.networkConnectionLost) }
        })
        await #expect(throws: URLError.self) {
            try await laptop.engine.pull(from: flaky)
        }
        #expect(laptop.tree("Notes").count == 2)

        let relaunched = try TestMac(named: "laptop", in: directory)
        await relaunched.engine.rescanAll()
        let report = try await relaunched.pull(from: studio)

        #expect(report.downloaded == 3)
        #expect(report.deleted == 0)
        #expect(relaunched.tree("Notes") == studio.tree("Notes"))
        #expect(try await studio.pull(from: relaunched) == SyncReport())
    }

    /// A Mac that joins through another Mac, never talking to the first,
    /// still ends up with everything, and its own files reach the first.
    @Test func joiningThroughAnotherMac() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let mini = try TestMac(named: "mini", in: directory)
        try studio.write("from studio", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await mini.pull(from: studio)

        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("from laptop", to: "Notes/b.txt")
        try await laptop.pull(from: mini)
        try await mini.pull(from: laptop)
        try await studio.pull(from: mini)

        for mac in [studio, mini, laptop] {
            #expect(mac.tree("Notes") == ["a.txt": "from studio", "b.txt": "from laptop"])
        }
    }
}
