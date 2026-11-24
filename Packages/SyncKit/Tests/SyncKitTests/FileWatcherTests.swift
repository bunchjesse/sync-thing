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
        #expect(FileWatcher.realPath(folder) != folder.path(percentEncoded: false))

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
}
