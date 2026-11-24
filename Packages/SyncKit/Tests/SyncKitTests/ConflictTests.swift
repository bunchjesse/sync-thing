import Foundation
import Testing
@testable import SyncKit

/// Two or three Macs changing the same paths before they sync.
struct ConflictTests {
    /// Makes `macs` sync `~/Notes` holding `files`, all dated long ago.
    private func start(_ macs: [TestMac], with files: [String: String]) async throws {
        for (path, contents) in files {
            try macs[0].write(contents, to: "Notes/\(path)", modified: ago(100_000))
        }
        try await macs[0].engine.addItem(at: macs[0].url("Notes"))
        try await syncAll(macs)
    }

    /// An edit made after another Mac deleted the file wins, and the file
    /// comes back there — even when the deleting Mac only noticed the
    /// deletion later, as when it was quit at the time.
    @Test func laterEditBeatsEarlierDeletion() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await start([studio, laptop], with: ["a.txt": "original"])

        try studio.remove("Notes/a.txt")
        try studio.setModified(ago(1000), of: "Notes")
        try laptop.write("edited", to: "Notes/a.txt", modified: ago(500))
        try await syncAll([studio, laptop])

        #expect(studio.read("Notes/a.txt") == "edited")
        #expect(laptop.read("Notes/a.txt") == "edited")
    }

    /// A deletion made after another Mac's edit wins on both.
    @Test func laterDeletionBeatsEarlierEdit() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await start([studio, laptop], with: ["a.txt": "original"])

        try laptop.write("edited", to: "Notes/a.txt", modified: ago(1000))
        try studio.remove("Notes/a.txt")
        try studio.setModified(ago(500), of: "Notes")
        try await syncAll([studio, laptop])

        #expect(studio.read("Notes/a.txt") == nil)
        #expect(laptop.read("Notes/a.txt") == nil)
    }

    /// A file recreated after its deletion synced — even a restored copy
    /// with an old modification time — reaches every Mac.
    @Test func recreatedFileOutranksItsDeletion() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await start([studio, laptop], with: ["a.txt": "original"])
        try studio.remove("Notes/a.txt")
        try await syncAll([studio, laptop])
        #expect(laptop.read("Notes/a.txt") == nil)

        try laptop.write("restored", to: "Notes/a.txt", modified: ago(200_000))
        try await syncAll([studio, laptop])

        #expect(studio.read("Notes/a.txt") == "restored")
        #expect(laptop.read("Notes/a.txt") == "restored")
    }

    /// A file replaced by a folder of the same name becomes that folder,
    /// with its contents, on the other Mac.
    @Test func fileBecomesFolder() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await start([studio, laptop], with: ["Thing": "a file"])

        try studio.remove("Notes/Thing")
        try studio.write("inside", to: "Notes/Thing/inside.txt")
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.failed == 0)
        #expect(laptop.tree("Notes") == ["Thing": "/", "Thing/inside.txt": "inside"])
    }

    /// A folder replaced by a file of the same name becomes that file on
    /// the other Mac in a single pull.
    @Test func folderBecomesFile() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await start([studio, laptop], with: ["Thing/inside.txt": "inside"])

        try studio.remove("Notes/Thing")
        try studio.write("a file", to: "Notes/Thing")
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.failed == 0)
        #expect(laptop.tree("Notes") == ["Thing": "a file"])
        #expect(try await laptop.pull(from: studio) == SyncReport())
    }

    /// When one Mac turns a folder into a file while another adds to the
    /// folder, the folder and what was added win on both, rather than the
    /// new file being lost.
    @Test func folderWithNewFilesBeatsTheFileReplacingIt() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await start([studio, laptop], with: ["Thing/inside.txt": "inside"])

        try laptop.write("added", to: "Notes/Thing/added.txt")
        await laptop.engine.rescanAll()
        try studio.remove("Notes/Thing")
        try studio.write("a file", to: "Notes/Thing")
        try await syncAll([studio, laptop])

        for mac in [studio, laptop] {
            #expect(mac.tree("Notes") == ["Thing": "/", "Thing/added.txt": "added"])
        }
    }

    /// A rename that only changes case reaches the other Mac in one pull,
    /// leaving one file under the new name.
    @Test func caseOnlyRename() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await start([studio, laptop], with: ["readme.txt": "hi"])

        try FileManager.default.moveItem(at: studio.url("Notes/readme.txt"), to: studio.url("Notes/README.txt"))
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.failed == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: laptop.url("Notes").path(percentEncoded: false)) == ["README.txt"])
        #expect(await laptop.engine.rescanAll() == false)
        #expect(try await studio.pull(from: laptop) == SyncReport())
    }

    /// A peer that lists two files whose names differ only in case, as one
    /// on a case-sensitive volume can, gets one of them here and the other
    /// reported as failed, rather than overwriting the first or retrying
    /// silently forever.
    @Test func namesDifferingOnlyInCaseAreReported() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let laptop = try TestMac(named: "laptop", in: directory)
        try FileManager.default.createDirectory(at: laptop.url("Notes"), withIntermediateDirectories: true)
        try await laptop.engine.addItem(at: laptop.url("Notes"))
        let version = ago(100).syncTimestamp
        let peer = FixedPeer(
            items: [SyncItem(id: "~/Notes", kind: .folder, version: 1)],
            records: [fileRecord("a.txt", "lower", version: version), fileRecord("A.txt", "upper", version: version)],
            contents: ["a.txt": "lower", "A.txt": "upper"]
        )

        let report = try await laptop.engine.pull(from: peer)

        #expect(report.downloaded == 1)
        #expect(report.failed == 1)
        #expect(laptop.tree("Notes").count == 1)
    }

    /// Files in a folder whose name differs only in case from one here are
    /// reported as failed, not put in this Mac's folder, where the next scan
    /// would see them under its name and the peer's copies as deleted.
    @Test func foldersDifferingOnlyInCaseAreReported() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("mine", to: "Notes/Docs/mine.txt", modified: ago(1_000))
        try await laptop.engine.addItem(at: laptop.url("Notes"))
        let version = ago(100).syncTimestamp
        let peer = FixedPeer(
            items: [SyncItem(id: "~/Notes", kind: .folder, version: 1)],
            records: [
                FileRecord(path: "Docs", kind: .directory, version: version, modified: version),
                fileRecord("Docs/mine.txt", "mine", version: ago(1_000).syncTimestamp),
                FileRecord(path: "docs", kind: .directory, version: version, modified: version),
                fileRecord("docs/theirs.txt", "theirs", version: version),
            ],
            contents: ["Docs/mine.txt": "mine", "docs/theirs.txt": "theirs"]
        )

        let report = try await laptop.engine.pull(from: peer)

        #expect(report.failed == 2)
        #expect(laptop.tree("Notes") == ["Docs": "/", "Docs/mine.txt": "mine"])
    }

    /// The same name in composed and decomposed Unicode is one file, so two
    /// Macs that spell it differently don't end up with two.
    @Test func unicodeNormalizationDoesNotDuplicate() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let decomposed = "Cafe\u{301}.txt"
        let composed = "Caf\u{E9}.txt"
        try studio.write("menu", to: "Notes/\(decomposed)", modified: ago(100))
        try laptop.write("menu", to: "Notes/\(composed)", modified: ago(200))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.engine.addItem(at: laptop.url("Notes"))

        try await syncAll([studio, laptop])

        #expect(laptop.tree("Notes").count == 1)
        #expect(studio.tree("Notes").count == 1)
        #expect(laptop.read("Notes/\(composed)") == "menu")
    }

    /// Two different edits with the very same modification time resolve the
    /// same way on both Macs.
    @Test func simultaneousEditsPickOneWinnerEverywhere() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await start([studio, laptop], with: ["a.txt": "original"])

        let moment = ago(10)
        try studio.write("studio's", to: "Notes/a.txt", modified: moment)
        try laptop.write("laptop's", to: "Notes/a.txt", modified: moment)
        try await syncAll([studio, laptop])

        #expect(studio.read("Notes/a.txt") == laptop.read("Notes/a.txt"))
        #expect(studio.timestamp("Notes/a.txt") == moment.syncTimestamp)
    }

    /// Three Macs each making different changes — an edit, a new file, a
    /// deletion, a new folder — all end up identical.
    @Test func threeMacsConverge() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        let mini = try TestMac(named: "mini", in: directory)
        try await start([studio, laptop, mini], with: ["a.txt": "a", "b.txt": "b", "c.txt": "c"])

        try studio.write("a edited", to: "Notes/a.txt", modified: ago(50))
        try laptop.write("new", to: "Notes/new.txt")
        try mini.remove("Notes/c.txt")
        try mini.write("deep", to: "Notes/Folder/deep.txt")
        try await syncAll([studio, laptop, mini])

        let expected = ["a.txt": "a edited", "b.txt": "b", "new.txt": "new", "Folder": "/", "Folder/deep.txt": "deep"]
        for mac in [studio, laptop, mini] {
            #expect(mac.tree("Notes") == expected)
            #expect(await mac.engine.rescanAll() == false)
        }
    }

    /// A file whose modification time changes but whose contents don't, as
    /// `touch` does, keeps its version, so nothing is sent anywhere.
    @Test func touchedFileIsNotSent() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try await start([studio, laptop], with: ["a.txt": "same"])
        let before = try laptop.modified("Notes/a.txt")

        try studio.setModified(ago(10), of: "Notes/a.txt")
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report == SyncReport())
        #expect(try laptop.modified("Notes/a.txt") == before)
        #expect(await studio.engine.rescanAll() == false)
    }

    /// Copies with the same contents but different modification times, as
    /// two Macs that each had the file before syncing do, are adopted
    /// rather than downloaded, and both keep the winner's time.
    @Test func sameContentsAreAdoptedNotDownloaded() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("same", to: "Notes/a.txt", modified: ago(10))
        try laptop.write("same", to: "Notes/a.txt", modified: ago(1000))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.engine.addItem(at: laptop.url("Notes"))

        let report = try await laptop.pull(from: studio)

        #expect(report == SyncReport())
        #expect(laptop.timestamp("Notes/a.txt") == studio.timestamp("Notes/a.txt"))
        #expect(await laptop.engine.rescanAll() == false)
        #expect(try await studio.pull(from: laptop) == SyncReport())
    }
}
