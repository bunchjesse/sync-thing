import Foundation
import Testing
@testable import SyncKit

struct FileWatcherTests {
    /// A change inside a watched folder is reported for its item, even when
    /// the folder's path runs through a symbolic link, as `/var` and `/tmp`
    /// do, so FSEvents reports a different path than the item's.
    @Test func reportsChangesInAFolderReachedThroughASymlink() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url.appending(path: "Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(SyncLocations.realPath(folder) != folder.path(percentEncoded: false))

        let (changes, continuation) = AsyncStream.makeStream(of: Set<String>.self)
        let watcher = FileWatcher { continuation.yield($0) }
        watcher.watch([(id: "~/Notes", url: folder, isFile: false)])
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try Data("hi".utf8).write(to: folder.appending(path: "new.txt"))
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            continuation.finish()
        }
        defer { timeout.cancel() }

        #expect(await changes.first { _ in true } == ["~/Notes"])
    }

    /// A change to a single-file item is reported for it, and a change to a
    /// sibling of the file isn't.
    @Test func reportsChangesToASingleFile() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: ".zshrc")
        try Data("a".utf8).write(to: file)

        let (changes, continuation) = AsyncStream.makeStream(of: Set<String>.self)
        let watcher = FileWatcher { continuation.yield($0) }
        watcher.watch([(id: "~/.zshrc", url: file, isFile: true)])
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try Data("sibling".utf8).write(to: directory.url.appending(path: "other.txt"))
        try await Task.sleep(for: .milliseconds(300))
        try Data("b".utf8).write(to: file)
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            continuation.finish()
        }
        defer { timeout.cancel() }

        for await changed in changes {
            #expect(changed == ["~/.zshrc"])
            break
        }
    }

    /// Watching a new set of items stops reporting the old ones.
    @Test func rewatchingReplacesTheOldItems() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let old = directory.url.appending(path: "Old", directoryHint: .isDirectory)
        let new = directory.url.appending(path: "New", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        let (changes, continuation) = AsyncStream.makeStream(of: Set<String>.self)
        let watcher = FileWatcher { continuation.yield($0) }
        watcher.watch([(id: "~/Old", url: old, isFile: false)])
        watcher.watch([(id: "~/New", url: new, isFile: false)])
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try Data("x".utf8).write(to: old.appending(path: "a.txt"))
        try Data("x".utf8).write(to: new.appending(path: "a.txt"))
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            continuation.finish()
        }
        defer { timeout.cancel() }

        #expect(await changes.first { _ in true } == ["~/New"])
    }
}
