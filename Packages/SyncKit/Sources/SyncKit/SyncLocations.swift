import Foundation

/// Milliseconds since 1970, the unit every sync version and modification
/// time is kept in.
///
/// Whole milliseconds survive JSON, `Date`, and the file system's own
/// timestamps unchanged, so a modification time copied from another Mac
/// reads back exactly as it was sent and never looks like a new change.
public typealias SyncTimestamp = Int64

extension Date {
    /// This date as a ``SyncTimestamp``, rounded to the nearest millisecond.
    var syncTimestamp: SyncTimestamp {
        SyncTimestamp((timeIntervalSince1970 * 1000).rounded())
    }

    /// The date a ``SyncTimestamp`` stands for.
    init(syncTimestamp: SyncTimestamp) {
        self.init(timeIntervalSince1970: Double(syncTimestamp) / 1000)
    }
}

/// Turns the paths a user picks into the portable form every Mac agrees
/// on, and back.
///
/// A path inside the home folder is written relative to it (`~/Documents/Notes`),
/// so a folder syncs between Macs whose user names differ. Anything else
/// keeps its absolute path.
public struct SyncLocations: Sendable, Hashable {
    /// The home folder `~` stands for on this Mac.
    public let home: URL

    /// Creates locations rooted at `home`, normally the user's home folder.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The portable path for `url`.
    public func portablePath(for url: URL) -> String {
        let path = Self.trimmingTrailingSlash(url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false))
        let trimmedHome = Self.trimmingTrailingSlash(home.path(percentEncoded: false))
        if path == trimmedHome {
            return "~"
        }
        if path.hasPrefix(trimmedHome + "/") {
            return "~/" + path.dropFirst(trimmedHome.count + 1)
        }
        return path
    }

    private static func trimmingTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The URL a portable path stands for on this Mac.
    public func url(forPortablePath portablePath: String) -> URL {
        if portablePath == "~" {
            return home
        }
        if portablePath.hasPrefix("~/") {
            return home.appending(path: String(portablePath.dropFirst(2)))
        }
        return URL(filePath: portablePath)
    }
}
