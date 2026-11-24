import Foundation
import Testing
@testable import SyncKit

/// Adding, removing, and re-adding items, and how the item list merges.
struct ItemTests {
    /// Removing an item on one Mac while another edits it stops it on both,
    /// and each keeps its own files as they were.
    @Test func removalWinsOverAnEditInFlight() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("original", to: "Notes/a.txt", modified: ago(1000))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try laptop.write("laptop edit", to: "Notes/a.txt")
        await laptop.engine.rescanAll()
        await studio.engine.removeItem(id: "~/Notes")
        try await syncAll([studio, laptop])

        #expect(await studio.engine.activeItems().isEmpty)
        #expect(await laptop.engine.activeItems().isEmpty)
        #expect(studio.read("Notes/a.txt") == "original")
        #expect(laptop.read("Notes/a.txt") == "laptop edit")
    }

    /// An item removed and added again syncs again everywhere, and what
    /// each Mac already has is adopted rather than downloaded again.
    @Test func readdedItemSyncsAgain() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("kept", to: "Notes/a.txt", modified: ago(1000))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)
        await studio.engine.removeItem(id: "~/Notes")
        try await laptop.pull(from: studio)

        try studio.write("new", to: "Notes/b.txt")
        try await studio.engine.addItem(at: studio.url("Notes"))
        let report = try await laptop.pull(from: studio)

        #expect(await laptop.engine.activeItems().map(\.id) == ["~/Notes"])
        #expect(report.downloaded == 1)
        #expect(laptop.tree("Notes") == ["a.txt": "kept", "b.txt": "new"])
    }

    /// Two Macs that each add one of two nested folders keep their own, and
    /// neither syncs into the other's.
    @Test func nestedItemsAddedOnTwoMacsStaySeparate() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("studio", to: "Projects/Other/a.txt")
        try laptop.write("laptop", to: "Projects/App/b.txt")
        try await studio.engine.addItem(at: studio.url("Projects"))
        try await laptop.engine.addItem(at: laptop.url("Projects/App"))

        try await syncAll([studio, laptop])

        #expect(await studio.engine.activeItems().map(\.id) == ["~/Projects"])
        #expect(await laptop.engine.activeItems().map(\.id) == ["~/Projects/App"])
        #expect(laptop.read("Projects/Other/a.txt") == nil)
    }

    /// An item that is a folder on one Mac and a file on another stays what
    /// it is on each, rather than one Mac's view replacing the other's.
    @Test func kindMismatchIsIgnored() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("in a folder", to: "Thing/a.txt")
        try laptop.write("a file", to: "Thing")
        try await studio.engine.addItem(at: studio.url("Thing"))
        try await laptop.engine.addItem(at: laptop.url("Thing"))

        try await syncAll([studio, laptop])

        #expect(await studio.engine.activeItems().map(\.kind) == [.folder])
        #expect(await laptop.engine.activeItems().map(\.kind) == [.file])
        #expect(studio.read("Thing/a.txt") == "in a folder")
        #expect(laptop.read("Thing") == "a file")
        #expect(await !studio.engine.isMissing("~/Thing"))
    }

    /// Adding refuses what can't be synced: nothing there, the home folder
    /// reached through a link, the root, and the engine's own state.
    @Test func addingRefusesWhatCantBeSynced() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try FileManager.default.createSymbolicLink(at: studio.url("Home"), withDestinationURL: studio.home)
        let state = directory.url.appending(path: "studio-state")
        let locations = SyncLocations(home: studio.home)

        await #expect(throws: SyncError.self) {
            try await studio.engine.addItem(at: studio.url("Nothing"))
        }
        await #expect(throws: SyncError.tooBroad("~")) {
            try await studio.engine.addItem(at: studio.url("Home"))
        }
        await #expect(throws: SyncError.tooBroad("/")) {
            try await studio.engine.addItem(at: URL(filePath: "/"))
        }
        await #expect(throws: SyncError.reserved(locations.portablePath(for: state))) {
            try await studio.engine.addItem(at: state)
        }
        await #expect(throws: SyncError.reserved(locations.portablePath(for: state.appending(path: "indexes")))) {
            try await studio.engine.addItem(at: state.appending(path: "indexes"))
        }
        await #expect(throws: SyncError.tooBroad(locations.portablePath(for: directory.url))) {
            try await studio.engine.addItem(at: directory.url)
        }
        #expect(await studio.engine.activeItems().isEmpty)
    }

    /// Adding a folder by another spelling — another case, or through a
    /// link — returns the item already synced instead of a second one.
    @Test func addingBySpellingAddsNothingNew() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        try studio.write("x", to: "Notes/a.txt")
        try FileManager.default.createSymbolicLink(at: studio.url("Shortcut"), withDestinationURL: studio.url("Notes"))
        let first = try await studio.engine.addItem(at: studio.url("Notes"))

        let lowercased = try await studio.engine.addItem(at: studio.url("notes"))
        let linked = try await studio.engine.addItem(at: studio.url("Shortcut"))

        #expect(lowercased == first)
        #expect(linked == first)
        #expect(await studio.engine.activeItems().map(\.id) == ["~/Notes"])
    }

    /// A peer's item spelled differently from how this Mac names the same
    /// place — another case, an absolute path into the home folder, a path
    /// through a link — is ignored, so no folder gets two items.
    @Test func peerItemsInAnotherSpellingAreIgnored() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let laptop = try TestMac(named: "laptop", in: directory)
        try laptop.write("x", to: "Notes/a.txt")
        try laptop.write("y", to: "Other/b.txt")
        try FileManager.default.createSymbolicLink(at: laptop.url("Shortcut"), withDestinationURL: laptop.url("Other"))
        try await laptop.engine.addItem(at: laptop.url("Notes"))
        let version = Date().syncTimestamp
        let peer = FixedPeer(items: [
            SyncItem(id: "~/notes", kind: .folder, version: version),
            SyncItem(id: laptop.url("Other").path(percentEncoded: false), kind: .folder, version: version),
            SyncItem(id: "~/Shortcut", kind: .folder, version: version),
        ])

        _ = try await laptop.engine.pull(from: peer)

        #expect(await laptop.engine.activeItems().map(\.id) == ["~/Notes"])
    }

    /// A single-file item's deletion reaches the other Mac.
    @Test func singleFileDeletionSyncs() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("export PATH", to: ".zshrc", modified: ago(1000))
        try await studio.engine.addItem(at: studio.url(".zshrc"))
        try await laptop.pull(from: studio)

        try studio.remove(".zshrc")
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.deleted == 1)
        #expect(laptop.read(".zshrc") == nil)
    }

    /// A single-file item replaced by a link — as dotfile managers do —
    /// pauses on that Mac rather than deleting the file everywhere, and the
    /// link's target is never served.
    @Test func singleFileReplacedByALinkPauses() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("export PATH", to: ".zshrc", modified: ago(1000))
        try studio.write("secret", to: "dotfiles/zshrc")
        try await studio.engine.addItem(at: studio.url(".zshrc"))
        try await laptop.pull(from: studio)

        try studio.remove(".zshrc")
        try FileManager.default.createSymbolicLink(at: studio.url(".zshrc"), withDestinationURL: studio.url("dotfiles/zshrc"))
        #expect(await studio.engine.servableFile(itemID: "~/.zshrc", path: "") == nil)
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(await studio.engine.isMissing("~/.zshrc"))
        #expect(report == SyncReport())
        #expect(laptop.read(".zshrc") == "export PATH")
    }

    /// A single-file item whose folder is gone pauses rather than deleting
    /// the file everywhere, and resumes when the folder is back.
    @Test func singleFileWithMissingFolderPauses() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("setting", to: "Config/app.conf", modified: ago(1000))
        try await studio.engine.addItem(at: studio.url("Config/app.conf"))
        try await laptop.pull(from: studio)

        try FileManager.default.moveItem(at: laptop.url("Config"), to: laptop.url("Config-away"))
        await laptop.engine.rescanAll()
        #expect(await laptop.engine.isMissing("~/Config/app.conf"))
        #expect(try await studio.pull(from: laptop) == SyncReport())
        #expect(studio.read("Config/app.conf") == "setting")

        try FileManager.default.moveItem(at: laptop.url("Config-away"), to: laptop.url("Config"))
        await laptop.engine.rescanAll()
        #expect(await !laptop.engine.isMissing("~/Config/app.conf"))
        #expect(await laptop.engine.rescanAll() == false)
    }

    /// A folder inside an item replaced by a link keeps its records, so the
    /// files under it aren't deleted elsewhere, and a deletion arriving
    /// from a peer is recorded without reaching through the link.
    @Test func subfolderReplacedByALinkIsLeftAlone() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let studio = try TestMac(named: "studio", in: directory)
        let laptop = try TestMac(named: "laptop", in: directory)
        try studio.write("one", to: "Notes/Sub/one.txt", modified: ago(1000))
        try studio.write("two", to: "Notes/Sub/two.txt", modified: ago(1000))
        try await studio.engine.addItem(at: studio.url("Notes"))
        try await laptop.pull(from: studio)

        try FileManager.default.moveItem(at: laptop.url("Notes/Sub"), to: laptop.url("Elsewhere"))
        try FileManager.default.createSymbolicLink(at: laptop.url("Notes/Sub"), withDestinationURL: laptop.url("Elsewhere"))
        await laptop.engine.rescanAll()
        #expect(try await studio.pull(from: laptop) == SyncReport())
        #expect(studio.tree("Notes/Sub").count == 2)

        try studio.remove("Notes/Sub/one.txt")
        await studio.engine.rescanAll()
        let report = try await laptop.pull(from: studio)

        #expect(report.failed == 0)
        #expect(laptop.read("Elsewhere/one.txt") == "one")
        #expect(await laptop.engine.rescanAll() == false)
    }
}
