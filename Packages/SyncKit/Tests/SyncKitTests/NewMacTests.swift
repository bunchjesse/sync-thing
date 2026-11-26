import Foundation
import Testing
@testable import SyncKit

/// A Mac with no sync state joining Macs that already sync: what it gets,
/// what it asks when it already has copies, and what it sends back.
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

    /// Writes copies of `Notes` on `studio`, which syncs it, and on `laptop`,
    /// which hasn't joined yet: one file the same, one newer on each Mac,
    /// and one only on each.
    private func makeDifferingCopies(studio: TestMac, laptop: TestMac) async throws {
        try studio.write("same", to: "Notes/same.txt", modified: ago(100))
        try laptop.write("same", to: "Notes/same.txt", modified: ago(900))
        try studio.write("studio newer", to: "Notes/studio-newer.txt", modified: ago(100))
        try laptop.write("laptop older", to: "Notes/studio-newer.txt", modified: ago(900))
        try studio.write("studio older", to: "Notes/laptop-newer.txt", modified: ago(900))
        try laptop.write("laptop newer", to: "Notes/laptop-newer.txt", modified: ago(100))
        try studio.write("studio only", to: "Notes/Studio/only.txt")
        try laptop.write("laptop only", to: "Notes/Laptop/only.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
    }

    /// A Mac whose copy of an item differs from the other Macs', made before
    /// it synced, holds the item and asks instead of merging by
    /// modification time, which a copy or clone can't be trusted with. It
    /// neither changes its copy nor offers it to the others meanwhile.
    @Test func differingCopyIsHeldForAChoice() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await makeDifferingCopies(studio: studio, laptop: laptop)
        let before = laptop.tree("Notes")

        let report = try await laptop.pull(from: studio)

        #expect(report == SyncReport())
        #expect(laptop.tree("Notes") == before)
        #expect(await laptop.engine.isAwaitingChoice("~/Notes"))
        #expect(await laptop.engine.joinQuestion() == JoinQuestion(items: [JoinQuestion.Item(id: "~/Notes", differingFiles: 4)]))
        #expect(try await studio.pull(from: laptop) == SyncReport())
        #expect(studio.read("Notes/Laptop/only.txt") == nil)
    }

    /// Taking the other Macs' copies makes this Mac's match theirs: its
    /// differing files and the ones only it has are moved aside, matching
    /// files keep the others' modification times, and nothing changes on
    /// the other Macs.
    @Test func usingOtherMacsCopiesReplacesThisMacs() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await makeDifferingCopies(studio: studio, laptop: laptop)
        let original = studio.tree("Notes")
        try await laptop.pull(from: studio)

        await laptop.answer(.useOtherMacs)
        try await laptop.pull(from: studio)
        try await studio.pull(from: laptop)

        #expect(await laptop.engine.joinQuestion() == nil)
        #expect(laptop.tree("Notes") == original)
        #expect(studio.tree("Notes") == original)
        #expect(laptop.timestamp("Notes/same.txt") == studio.timestamp("Notes/same.txt"))
        #expect(try await laptop.pull(from: studio) == SyncReport())
    }

    /// Taking this Mac's copies makes every other Mac's match it: their
    /// differing files are replaced, and the ones only they have are
    /// deleted there.
    @Test func usingThisMacsCopiesReplacesTheOthers() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let mini = try TestMac(named: "mini", in: directory)
        try await makeDifferingCopies(studio: studio, laptop: laptop)
        try await mini.pull(from: studio)
        let original = laptop.tree("Notes")
        try await laptop.pull(from: studio)

        await laptop.answer(.useThisMac)
        try await studio.pull(from: laptop)
        try await mini.pull(from: studio)
        try await laptop.pull(from: studio)

        #expect(laptop.tree("Notes") == original)
        #expect(studio.tree("Notes") == original)
        #expect(mini.tree("Notes") == original)
    }

    /// Taking this Mac's copies beats every Mac it heard from, not just the
    /// last: a file only a second Mac has is deleted there too.
    @Test func usingThisMacsCopiesBeatsEveryMac() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let mini = try TestMac(named: "mini", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("studio", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await mini.pull(from: studio)
        try mini.write("only on mini", to: "Notes/mini.txt")
        await mini.engine.rescanAll()
        try laptop.write("laptop", to: "Notes/a.txt")
        try await laptop.pull(from: mini)
        try await laptop.pull(from: studio)

        await laptop.answer(.useThisMac)
        try await syncAll([studio, mini, laptop])

        for mac in [studio, mini, laptop] {
            #expect(mac.tree("Notes") == ["a.txt": "laptop"])
        }
    }

    /// Taking the other Macs' copies gives way on files deleted here while
    /// the question waited too: the others' copies come back rather than
    /// the deletion reaching them.
    @Test func usingOtherMacsCopiesOverridesDeletionsMadeWhileWaiting() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await makeDifferingCopies(studio: studio, laptop: laptop)
        let original = studio.tree("Notes")
        try await laptop.pull(from: studio)
        try laptop.remove("Notes/studio-newer.txt")
        await laptop.engine.rescanAll()

        await laptop.answer(.useOtherMacs)
        try await syncAll([studio, laptop])

        #expect(studio.tree("Notes") == original)
        #expect(laptop.tree("Notes") == original)
    }

    /// A file that can't be moved aside leaves the item waiting, with what
    /// was settled kept, so it never syncs half decided; answering again
    /// once it can be moved finishes the job.
    @Test func itemThatCannotBeSettledStaysHeld() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await makeDifferingCopies(studio: studio, laptop: laptop)
        let original = studio.tree("Notes")
        try await laptop.pull(from: studio)
        let locked = laptop.url("Notes/Laptop").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        await laptop.answer(.useOtherMacs)

        #expect(await laptop.engine.isAwaitingChoice("~/Notes"))
        #expect(try await studio.pull(from: laptop) == SyncReport())

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        try await laptop.pull(from: studio)
        await laptop.answer(.useOtherMacs)
        try await laptop.pull(from: studio)

        #expect(await !laptop.engine.isAwaitingChoice("~/Notes"))
        #expect(laptop.tree("Notes") == original)
    }

    /// A folder only this Mac has that holds something SyncThing doesn't
    /// sync, such as a symbolic link, is kept when its files go aside,
    /// rather than going to the Trash with the link.
    @Test func folderHoldingUnsyncedThingsIsKept() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("a", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try laptop.write("mine", to: "Notes/Local/mine.txt")
        try FileManager.default.createSymbolicLink(at: laptop.url("Notes/Local/link"), withDestinationURL: laptop.home)
        try await laptop.pull(from: studio)

        await laptop.answer(.useOtherMacs)
        try await laptop.pull(from: studio)

        #expect(await !laptop.engine.isAwaitingChoice("~/Notes"))
        #expect(laptop.read("Notes/a.txt") == "a")
        #expect(laptop.read("Notes/Local/mine.txt") == nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: laptop.url("Notes/Local/link").path(percentEncoded: false))) != nil)
    }

    /// A Mac whose copy has nothing the others lack — matching files, or
    /// fewer — has nothing to choose, so it takes the others' copy at once.
    @Test func copyWithNothingNewSyncsWithoutAsking() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("same", to: "Notes/same.txt", modified: ago(100))
        try studio.write("more", to: "Notes/more.txt")
        try laptop.write("same", to: "Notes/same.txt", modified: ago(10))
        try await studio.engine.addItem(at: studio.url("Notes"))

        let report = try await laptop.pull(from: studio)

        #expect(report.downloaded == 1)
        #expect(await laptop.engine.joinQuestion() == nil)
        #expect(laptop.tree("Notes") == studio.tree("Notes"))
        #expect(laptop.timestamp("Notes/same.txt") == studio.timestamp("Notes/same.txt"))
    }

    /// One answer settles every item that waits, folders and single files
    /// alike.
    @Test func oneAnswerSettlesEveryItem() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("studio", to: "Notes/a.txt")
        try studio.write("studio", to: ".zshrc")
        try laptop.write("laptop", to: "Notes/a.txt")
        try laptop.write("laptop", to: ".zshrc")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await studio.engine.addItem(at: studio.url(".zshrc"))
        try await laptop.pull(from: studio)
        #expect(await laptop.engine.joinQuestion()?.items.map(\.id) == ["~/.zshrc", "~/Notes"])

        await laptop.answer(.useThisMac)
        try await studio.pull(from: laptop)

        #expect(await laptop.engine.joinQuestion() == nil)
        #expect(studio.read("Notes/a.txt") == "laptop")
        #expect(studio.read(".zshrc") == "laptop")
    }

    /// An item waiting for a choice still waits after a relaunch, rather
    /// than merging by modification time with the index its scan saved.
    @Test func heldItemStaysHeldAcrossARelaunch() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await makeDifferingCopies(studio: studio, laptop: laptop)
        try await laptop.pull(from: studio)

        let relaunched = try TestMac(named: "laptop", in: directory)
        await relaunched.engine.rescanAll()
        let report = try await relaunched.pull(from: studio)

        #expect(report == SyncReport())
        #expect(await relaunched.engine.joinQuestion()?.items.map(\.id) == ["~/Notes"])
        #expect(try await studio.pull(from: relaunched) == SyncReport())
    }

    /// Two Macs that both hold the same item don't take each other's copy
    /// as the answer: neither offers its own.
    @Test func heldCopiesAreNotOfferedToOtherJoiningMacs() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let mini = try TestMac(named: "mini", in: directory)
        try studio.write("studio", to: "Notes/a.txt")
        try laptop.write("laptop", to: "Notes/a.txt")
        try mini.write("mini", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)
        try await mini.pull(from: laptop)

        #expect(await mini.engine.isAwaitingChoice("~/Notes"))
        #expect(await mini.engine.joinQuestion() == nil)
        #expect(mini.read("Notes/a.txt") == "mini")
    }

    /// An item the other Macs stop syncing while it waits for a choice
    /// stops waiting, and its files stay as they were.
    @Test func itemRemovedWhileHeldStopsWaiting() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await makeDifferingCopies(studio: studio, laptop: laptop)
        let before = laptop.tree("Notes")
        try await laptop.pull(from: studio)

        await studio.engine.removeItem(id: "~/Notes")
        try await laptop.pull(from: studio)

        #expect(await laptop.engine.activeItems().isEmpty)
        #expect(await laptop.engine.joinQuestion() == nil)
        #expect(laptop.tree("Notes") == before)
    }

    /// Whichever copy is chosen, the other Macs' deletions are part of
    /// theirs: taking theirs deletes this Mac's copies of the files they
    /// deleted, and taking this Mac's brings those files back.
    @Test(arguments: [JoinChoice.useOtherMacs, .useThisMac])
    func deletionsFollowTheChoice(choice: JoinChoice) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("x", to: "Notes/deleted.txt", modified: ago(10_000))
        try studio.write("keep", to: "Notes/keep.txt", modified: ago(10_000))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try studio.remove("Notes/deleted.txt")
        await studio.engine.rescanAll()

        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("laptop copy", to: "Notes/deleted.txt", modified: ago(100))
        try laptop.write("keep", to: "Notes/keep.txt", modified: ago(10_000))
        try await laptop.pull(from: studio)
        await laptop.answer(choice)
        try await syncAll([studio, laptop])

        let expected = choice == .useOtherMacs ? nil : "laptop copy"
        #expect(laptop.read("Notes/deleted.txt") == expected)
        #expect(studio.read("Notes/deleted.txt") == expected)
        #expect(studio.read("Notes/keep.txt") == "keep")
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
    /// still ends up with everything, and files it adds afterwards reach
    /// the first.
    @Test func joiningThroughAnotherMac() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let mini = try TestMac(named: "mini", in: directory)
        try studio.write("from studio", to: "Notes/a.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await mini.pull(from: studio)

        let laptop = try TestMac(named: "laptop", in: directory)
        try await laptop.pull(from: mini)
        try laptop.write("from laptop", to: "Notes/b.txt")
        await laptop.engine.rescanAll()
        try await mini.pull(from: laptop)
        try await studio.pull(from: mini)

        for mac in [studio, mini, laptop] {
            #expect(mac.tree("Notes") == ["a.txt": "from studio", "b.txt": "from laptop"])
        }
    }
}
