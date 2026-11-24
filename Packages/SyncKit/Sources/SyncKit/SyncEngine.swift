import Foundation
import os

/// One Mac's side of syncing: the item list, each item's index, and the
/// rules for pulling a peer's changes onto disk.
///
/// The engine never pushes. ``pull(from:)`` downloads whatever a peer has
/// that is newer — newest change wins, path by path — and the peer pulls
/// from this Mac in turn when told something changed (``Event``).
///
/// Scanning, hashing, and downloading run off the actor, so it can take
/// other calls meanwhile; every change to an index is therefore checked
/// against the state it was planned from before it lands: a scan whose
/// index changed meanwhile runs again, and a download whose path changed on
/// either side is skipped and picked up by the next pull. The small
/// file-system change that places each file runs on the actor, together
/// with that check, so nothing can slip in between them.
public actor SyncEngine {
    /// A change to this Mac's sync state, which peers should pull.
    public enum Event: Sendable, Equatable {
        /// The item list changed.
        case itemsChanged
        /// The index of an item changed: its files changed on disk, or a
        /// pull brought changes from a peer.
        case filesChanged(itemID: String)
        /// An item's root went missing or came back.
        case availabilityChanged(itemID: String)
    }

    /// Where portable paths point on this Mac.
    nonisolated let locations: SyncLocations

    private let store: SyncStore
    private let removeFile: @Sendable (URL) throws -> Void
    private var items: [String: SyncItem]
    private var indexes: [String: [String: FileRecord]] = [:]
    /// Bumped on every change to an item's index, so a scan that ran while
    /// a pull changed the index knows its result is stale.
    private var generations: [String: Int] = [:]
    private var missingRoots: Set<String> = []
    private var scanning: Set<String> = []
    private var rescanRequested: Set<String> = []
    private var dirtyIndexes: Set<String> = []
    private var observer: (@Sendable (Event) -> Void)?

    private static let log = Logger(subsystem: "dev.bunch.SyncKit", category: "engine")
    private static let ioQueue = DispatchQueue(label: "dev.bunch.SyncKit.io", qos: .utility, attributes: .concurrent)

    /// Creates an engine that keeps its state in `stateDirectory`.
    ///
    /// - Parameter removeFile: Disposes of a file a peer deleted. Defaults to
    ///   moving it to the Trash, so a deletion that arrives by mistake can
    ///   be undone.
    public init(
        locations: SyncLocations,
        stateDirectory: URL,
        removeFile: @escaping @Sendable (URL) throws -> Void = SyncEngine.moveToTrash
    ) throws {
        self.locations = locations
        self.removeFile = removeFile
        let store = try SyncStore(directory: stateDirectory)
        self.store = store
        let loaded = store.loadItems()
        self.items = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in loaded where !item.isRemoved {
            indexes[item.id] = store.loadIndex(itemID: item.id)
        }
    }

    /// Moves `url` to the Trash, deleting it outright only on a volume that
    /// has no Trash. Any other failure is thrown, and the file stays.
    public static let moveToTrash: @Sendable (URL) throws -> Void = { url in
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch CocoaError.featureUnsupported {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Calls `observer` with every ``Event`` from now on, replacing any
    /// earlier observer.
    public func observe(_ observer: @escaping @Sendable (Event) -> Void) {
        self.observer = observer
    }

    // MARK: - Items

    /// The items being synced, sorted by path.
    public func activeItems() -> [SyncItem] {
        items.values.filter { !$0.isRemoved }.sorted { $0.id < $1.id }
    }

    /// Every item, including removed ones, as peers need to see them.
    public func allItems() -> [SyncItem] {
        items.values.sorted { $0.id < $1.id }
    }

    /// Whether `itemID`'s root is missing on this Mac, which pauses it.
    public func isMissing(_ itemID: String) -> Bool {
        missingRoots.contains(itemID)
    }

    /// How many files `itemID` has on this Mac.
    public func fileCount(_ itemID: String) -> Int {
        indexes[itemID]?.values.count { $0.kind == .file && !$0.isDeleted } ?? 0
    }

    /// Where `item` lives on this Mac.
    public nonisolated func url(for item: SyncItem) -> URL {
        locations.url(forPortablePath: item.id)
    }

    /// Starts syncing the folder or file at `url` on every Mac, or returns
    /// the item when it's already synced. Throws a ``SyncError`` when the
    /// path can't be synced.
    @discardableResult
    public func addItem(at url: URL) async throws -> SyncItem {
        let resolved = URL(filePath: SyncLocations.realPath(url.standardizedFileURL))
        let path = resolved.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { throw SyncError.notFound(path) }
        let id = locations.portablePath(for: resolved)
        if let problem = admissionProblem(for: id) { throw problem }
        if let existing = items[id], !existing.isRemoved {
            return existing
        }

        let kind: SyncItem.Kind = FileScanner.isDirectory(resolved) ? .folder : .file
        let item = SyncItem(id: id, kind: kind, version: Self.nextVersion(after: items[id]?.version))
        items[id] = item
        indexes[id] = nil
        saveItems()
        Self.log.notice("Added \(id, privacy: .private)")
        observer?(.itemsChanged)
        await rescan(itemID: id)
        return item
    }

    /// Stops syncing `itemID` on every Mac. Its files stay where they are.
    public func removeItem(id itemID: String) {
        guard let item = items[itemID], !item.isRemoved else { return }
        items[itemID] = SyncItem(id: itemID, kind: item.kind, version: Self.nextVersion(after: item.version), isRemoved: true)
        forgetIndex(itemID)
        saveItems()
        Self.log.notice("Removed \(itemID, privacy: .private)")
        observer?(.itemsChanged)
    }

    /// Why `id` can't be synced on this Mac, or nil when it can: it must not
    /// be the home folder, the root, a volume, or a folder holding the home
    /// folder or this engine's own state, and it must not overlap another
    /// active item. Every rule is judged by where the path really leads, so
    /// a symbolic link or a name that differs only in case can't get around
    /// one.
    private func admissionProblem(for id: String) -> SyncError? {
        let url = url(forPortablePath: id)
        let realPath = SyncLocations.realPath(url)
        let isVolume = (try? URL(filePath: realPath).resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
        let home = SyncLocations.realPath(locations.home)
        if id == "~" || realPath == "/" || isVolume || Self.isSameOrInside(home, realPath) {
            return .tooBroad(id)
        }
        let state = SyncLocations.realPath(store.directory)
        if Self.isSameOrInside(state, realPath) || Self.isSameOrInside(realPath, state) {
            return .reserved(id)
        }
        for other in activeItems() where other.id != id {
            let otherPath = SyncLocations.realPath(self.url(for: other))
            if Self.isSameOrInside(realPath, otherPath) { return .insideSyncedItem(parent: other.id) }
            if Self.isSameOrInside(otherPath, realPath) { return .containsSyncedItem(child: other.id) }
        }
        return nil
    }

    private nonisolated func url(forPortablePath id: String) -> URL {
        locations.url(forPortablePath: id)
    }

    /// The portable path this Mac gives the place `id` leads to.
    private nonisolated func canonicalID(for id: String) -> String {
        locations.portablePath(for: url(forPortablePath: id))
    }

    /// Adopts every entry in a peer's item list that is newer than this
    /// Mac's. Returns the items that became active here. An entry this Mac
    /// wouldn't accept from its own user (``admissionProblem(for:)``) is
    /// ignored, as is one this Mac would name differently — an absolute
    /// path into the home folder, a name in another case, or a path through
    /// a symbolic link — and one that would turn an active folder into a
    /// file or the other way round.
    private func mergeItems(_ remote: [SyncItem]) -> [SyncItem] {
        var added: [SyncItem] = []
        var changed = false
        let now = Date().syncTimestamp
        for item in remote where Self.isSafeItemID(item.id) && Self.isPlausible(item.version, now: now) {
            if let current = items[item.id], !item.supersedes(current) { continue }
            let current = items[item.id].flatMap { $0.isRemoved ? nil : $0 }
            if !item.isRemoved {
                if let current, current.kind != item.kind {
                    Self.log.error("Ignoring \(item.id, privacy: .private) from a peer: it's a \(item.kind.rawValue, privacy: .public) there")
                    continue
                }
                if current == nil, canonicalID(for: item.id) != item.id {
                    Self.log.error("Ignoring \(item.id, privacy: .private) from a peer: this Mac names it \(self.canonicalID(for: item.id), privacy: .private)")
                    continue
                }
                if current == nil, let problem = admissionProblem(for: item.id) {
                    Self.log.error("Ignoring \(item.id, privacy: .private) from a peer: \(problem.localizedDescription, privacy: .private)")
                    continue
                }
            }
            items[item.id] = item
            changed = true
            if item.isRemoved {
                forgetIndex(item.id)
            } else if current == nil {
                createRootIfNew(item)
                added.append(item)
            }
        }
        if changed {
            saveItems()
            observer?(.itemsChanged)
        }
        return added
    }

    /// Creates the folder an item with no index on this Mac lives in, so it
    /// can be filled. An item with an index is never given a new root: that
    /// it's gone means a drive isn't mounted, or the user moved it, and the
    /// item waits rather than syncing into a new, empty folder.
    private func createRootIfNew(_ item: SyncItem) {
        guard indexes[item.id] == nil, store.loadIndex(itemID: item.id) == nil else { return }
        let root = url(for: item)
        let folder = item.kind == .folder ? root : root.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Self.log.error("Couldn't create the folder for \(item.id, privacy: .private): \(error.localizedDescription, privacy: .private)")
        }
    }

    private func forgetIndex(_ itemID: String) {
        indexes[itemID] = nil
        generations[itemID, default: 0] += 1
        missingRoots.remove(itemID)
        dirtyIndexes.remove(itemID)
        store.removeIndex(itemID: itemID)
    }

    private func saveItems() {
        do {
            try store.save(items: Array(items.values))
        } catch {
            Self.log.error("Couldn't save the item list: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Scanning

    /// Brings `itemID`'s index up to date with the disk. Returns whether it
    /// changed. A call made while the item is being scanned makes that
    /// scan run once more and returns at once.
    @discardableResult
    public func rescan(itemID: String) async -> Bool {
        guard let item = items[itemID], !item.isRemoved else { return false }
        guard !scanning.contains(itemID) else {
            rescanRequested.insert(itemID)
            return false
        }
        scanning.insert(itemID)
        defer { scanning.remove(itemID) }

        var changed = false
        repeat {
            rescanRequested.remove(itemID)
            // An item that comes back after this Mac lost its item list
            // still has its saved index, tombstones and all.
            let previous = indexes[itemID] ?? store.loadIndex(itemID: itemID) ?? [:]
            let generation = generations[itemID, default: 0]
            let root = url(for: item)
            let now = Date().syncTimestamp
            let outcome = await Self.onIOQueue {
                FileScanner.scan(root: root, kind: item.kind, previous: previous, now: now)
            }
            guard items[itemID]?.isRemoved == false else { return changed }
            guard generation == generations[itemID, default: 0] else {
                rescanRequested.insert(itemID)
                continue
            }
            switch outcome {
            case .rootMissing:
                if missingRoots.insert(itemID).inserted {
                    Self.log.notice("\(itemID, privacy: .private) is missing; pausing it")
                    observer?(.availabilityChanged(itemID: itemID))
                }
            case .scanned(let records):
                if missingRoots.remove(itemID) != nil {
                    observer?(.availabilityChanged(itemID: itemID))
                }
                if indexes[itemID] == nil || records != previous {
                    indexes[itemID] = records
                    generations[itemID, default: 0] += 1
                    dirtyIndexes.insert(itemID)
                    changed = true
                }
            }
        } while rescanRequested.contains(itemID)

        flush(itemID)
        if changed {
            observer?(.filesChanged(itemID: itemID))
        }
        return changed
    }

    /// Rescans every item. Returns whether any index changed.
    @discardableResult
    public func rescanAll() async -> Bool {
        var changed = false
        for item in activeItems() where await rescan(itemID: item.id) {
            changed = true
        }
        return changed
    }

    // MARK: - Serving

    /// This Mac's index of `itemID`, for a peer to pull, or nil while the
    /// item isn't synced here or its root is missing.
    public func records(forItem itemID: String) -> [FileRecord]? {
        guard items[itemID]?.isRemoved == false, !missingRoots.contains(itemID), let index = indexes[itemID] else { return nil }
        return index.values.sorted { $0.path < $1.path }
    }

    /// The file a peer may download at `path` in `itemID`: only a file this
    /// Mac's index lists, reached without following a symbolic link inside
    /// the item, so a request can never reach outside it.
    public func servableFile(itemID: String, path: String) -> URL? {
        guard let item = items[itemID], !item.isRemoved, !missingRoots.contains(itemID),
              Self.isSafe(path: path, in: item),
              let record = indexes[itemID]?[path], record.kind == .file, !record.isDeleted else { return nil }
        let file = fileURL(in: item, path: path)
        guard Self.hasNoLinks(below: url(for: item), to: file, includingTarget: true) else { return nil }
        return file
    }

    // MARK: - Pulling

    /// Brings this Mac up to date with `peer`: adopts its newer item-list
    /// entries, then downloads, deletes, and creates whatever paths it has
    /// newer versions of. Throws when the peer can't be reached; a single
    /// path that fails is counted in the report and tried again next time.
    public func pull(from peer: some SyncPeer) async throws -> SyncReport {
        var report = SyncReport()
        for item in mergeItems(try await peer.items()) {
            await rescan(itemID: item.id)
        }
        for item in activeItems() {
            if indexes[item.id] == nil {
                await rescan(itemID: item.id)
            }
            guard indexes[item.id] != nil, !missingRoots.contains(item.id) else { continue }
            guard let remote = try await peer.records(forItem: item.id) else { continue }
            try await pull(item, records: remote, from: peer, into: &report)
        }
        return report
    }

    /// One change a pull will make, and the local record it was planned
    /// against.
    private struct Action {
        /// What the change does. Actions run in this order: deletions clear
        /// the way for a folder that becomes a file and for a name whose
        /// case changed, and directories exist before files land in them.
        enum Kind: Int, Comparable {
            case deleteFile, deleteDirectory, createDirectory, download, adopt
            static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let kind: Kind
        let remote: FileRecord
        let expected: FileRecord?

        /// How many components the path has. Directories are created
        /// shallowest first and deleted deepest first.
        var depth: Int { remote.path.split(separator: "/").count }
    }

    /// What applying one ``Action`` did.
    private enum Applied {
        /// Nothing: the path changed since the plan was made.
        case skipped
        /// The change was made.
        case done
        /// A directory the peer deleted was kept, because this Mac still
        /// has files in it.
        case keptDirectory
        /// The index took the change, but the disk was left alone.
        case recorded
    }

    /// Pulls `item` from `peer`, whose index of it is `records`, adding
    /// what it did to `report`. Downloads go to a staging folder and are
    /// checked against the record's hash before they're placed. Whatever
    /// was applied is saved and announced even when the peer goes away
    /// partway through.
    private func pull(_ item: SyncItem, records: [FileRecord], from peer: some SyncPeer, into report: inout SyncReport) async throws {
        let actions = plan(item, remote: records)
        guard !actions.isEmpty else { return }
        let changedBefore = report

        var staging: URL?
        defer {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            if dirtyIndexes.contains(item.id) {
                flush(item.id)
                observer?(.filesChanged(itemID: item.id))
            }
        }
        for action in actions {
            try Task.checkCancellation()
            var download: URL?
            if action.kind == .download {
                guard Self.hasNoLinks(below: url(for: item), to: fileURL(in: item, path: action.remote.path), includingTarget: true) else {
                    Self.log.error("Not downloading \(action.remote.path, privacy: .private): a symbolic link is in the way")
                    report.failed += 1
                    continue
                }
                do {
                    let directory = try staging ?? stagingDirectory(for: item)
                    staging = directory
                    let destination = directory.appending(path: UUID().uuidString)
                    try await peer.download(itemID: item.id, path: action.remote.path, to: destination)
                    let hash = try await Self.onIOQueue { try FileScanner.hash(of: destination) }
                    guard hash == action.remote.hash else {
                        // The file changed on the peer mid-download; the
                        // peer's next index has the new version.
                        report.failed += 1
                        continue
                    }
                    download = destination
                } catch {
                    if Self.isConnectionFailure(error) { throw error }
                    Self.log.error("Couldn't download \(action.remote.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    report.failed += 1
                    continue
                }
            }
            do {
                switch try apply(action, to: item, download: download) {
                case .skipped, .keptDirectory, .recorded:
                    break
                case .done:
                    switch action.kind {
                    case .download: report.downloaded += 1
                    case .deleteFile, .deleteDirectory: report.deleted += 1
                    case .createDirectory, .adopt: break
                    }
                }
            } catch {
                Self.log.error("Couldn't apply \(action.remote.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
                report.failed += 1
            }
        }
        if report != changedBefore {
            let downloaded = report.downloaded - changedBefore.downloaded
            let deleted = report.deleted - changedBefore.deleted
            let failed = report.failed - changedBefore.failed
            Self.log.info("Pulled \(item.id, privacy: .private): \(downloaded) downloaded, \(deleted) deleted, \(failed) failed")
        }
    }

    /// The changes that bring `item` up to date with a peer's `remote`
    /// records, in the order they must happen. Records with impossible
    /// paths, sizes, or timestamps are ignored, as are tombstones this Mac
    /// has already pruned or would prune.
    private func plan(_ item: SyncItem, remote: [FileRecord]) -> [Action] {
        let local = indexes[item.id] ?? [:]
        let now = Date().syncTimestamp
        var actions: [Action] = []
        for record in remote where Self.isSafe(path: record.path, in: item) && Self.isPlausible(record, now: now) {
            let current = local[record.path]
            let isExpired = record.isDeleted && now - record.version >= FileScanner.tombstoneLifetime
            if isExpired, current == nil || current?.isDeleted == true { continue }
            if let current, current.hasSameContent(as: record) {
                if record.supersedes(current) {
                    actions.append(Action(kind: .adopt, remote: record, expected: current))
                }
                continue
            }
            if let current, !record.supersedes(current) { continue }
            let kind: Action.Kind
            if record.isDeleted {
                if current == nil || current?.isDeleted == true {
                    kind = .adopt
                } else {
                    kind = current?.kind == .directory ? .deleteDirectory : .deleteFile
                }
            } else {
                kind = record.kind == .directory ? .createDirectory : .download
            }
            actions.append(Action(kind: kind, remote: record, expected: current))
        }
        return actions.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.kind == .deleteDirectory ? lhs.depth > rhs.depth : lhs.depth < rhs.depth
        }
    }

    /// Makes one planned change on disk and in the index. Changes nothing
    /// when the path changed since the plan was made — in the index, or on
    /// disk ahead of the next scan, which is then asked for so the change
    /// reaches the peers instead of being overwritten.
    ///
    /// Symbolic links aren't synced and would lead outside the item, so when
    /// the path or a folder on the way is one, a deletion is only recorded
    /// and anything else throws. A path that, or a folder on the way that,
    /// differs only in case from an indexed one throws too.
    private func apply(_ action: Action, to item: SyncItem, download: URL?) throws -> Applied {
        guard items[item.id]?.isRemoved == false, !missingRoots.contains(item.id), var index = indexes[item.id] else { return .skipped }
        let path = action.remote.path
        guard index[path] == action.expected else { return .skipped }
        let root = url(for: item)
        let url = fileURL(in: item, path: path)
        guard Self.hasNoLinks(below: root, to: url, includingTarget: true) else {
            guard action.kind == .deleteFile || action.kind == .deleteDirectory else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
            }
            index[path] = action.remote
            indexes[item.id] = index
            generations[item.id, default: 0] += 1
            dirtyIndexes.insert(item.id)
            return .recorded
        }
        guard Self.disk(at: url, matches: action.expected) else {
            if action.expected == nil, Self.caseClash(for: path, in: index) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
            }
            rescanRequested.insert(item.id)
            Task { await rescan(itemID: item.id) }
            return .skipped
        }
        if Self.caseClash(for: path, in: index, ancestorsOnly: true) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }

        var record = action.remote
        var applied = Applied.done
        switch action.kind {
        case .adopt:
            if record.kind == .file, !record.isDeleted {
                (record.modified, record.size) = try Self.setModified(record.modified, of: url)
            }
        case .createDirectory:
            if action.expected?.kind == .file, action.expected?.isDeleted == false {
                try removeFile(url)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        case .download:
            guard let download else { return .skipped }
            if action.expected?.kind == .directory, action.expected?.isDeleted == false {
                guard Self.isEffectivelyEmpty(url) else {
                    // The peer made a file of a folder this Mac still has
                    // files in; the folder stays, and goes back to the peer.
                    record = FileRecord(path: path, kind: .directory, version: Self.nextVersion(after: record.version), modified: Date().syncTimestamp)
                    applied = .keptDirectory
                    break
                }
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: download)
            } else {
                try FileManager.default.moveItem(at: download, to: url)
            }
            (record.modified, record.size) = try Self.setModified(record.modified, of: url)
        case .deleteFile:
            try removeFile(url)
        case .deleteDirectory:
            if Self.isEffectivelyEmpty(url) {
                try FileManager.default.removeItem(at: url)
            } else {
                // Something this Mac still has lives in it, so the directory
                // stays, and goes back to the peer with it.
                record = FileRecord(path: path, kind: .directory, version: Self.nextVersion(after: record.version), modified: Date().syncTimestamp)
                applied = .keptDirectory
            }
        }
        index[path] = record
        indexes[item.id] = index
        generations[item.id, default: 0] += 1
        dirtyIndexes.insert(item.id)
        return applied
    }

    // MARK: - Helpers

    /// Writes `itemID`'s index to disk if it changed.
    private func flush(_ itemID: String) {
        guard dirtyIndexes.remove(itemID) != nil, let index = indexes[itemID] else { return }
        do {
            try store.save(index: index, itemID: itemID)
        } catch {
            Self.log.error("Couldn't save the index of \(itemID, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Where `path` in `item` lives on this Mac.
    private func fileURL(in item: SyncItem, path: String) -> URL {
        let root = url(for: item)
        return path.isEmpty ? root : root.appending(path: path)
    }

    /// A scratch directory on the same volume as `item`, so a finished
    /// download moves into place atomically.
    private func stagingDirectory(for item: SyncItem) throws -> URL {
        let root = url(for: item)
        let anchor = item.kind == .folder ? root : root.deletingLastPathComponent()
        return try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: anchor, create: true)
    }

    /// The version a local change gets: now, or just after `previous` when
    /// the clock says otherwise.
    private static func nextVersion(after previous: SyncTimestamp?) -> SyncTimestamp {
        max(Date().syncTimestamp, (previous ?? 0) + 1)
    }

    /// Whether `path` is one a peer may name in `item`: the root itself for a
    /// file, otherwise a relative path with no `..`, `.`, or ignored names.
    static func isSafe(path: String, in item: SyncItem) -> Bool {
        if item.kind == .file { return path.isEmpty }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !hasControlCharacters(path) && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && !FileScanner.isIgnored(String(component))
        }
    }

    /// Whether `id` is a portable path this Mac may sync: inside the home
    /// folder, or absolute, in canonical form — no empty, `.`, or `..`
    /// components, and no trailing slash.
    static func isSafeItemID(_ id: String) -> Bool {
        let prefix = id.hasPrefix("~/") ? "~/" : id.hasPrefix("/") ? "/" : nil
        guard let prefix, !hasControlCharacters(id) else { return false }
        let components = id.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Whether `path`, or with `ancestorsOnly` one of its folders, is spelled
    /// differently only in case from a live entry in `index` — two names a
    /// case-insensitive disk would put in one place. A folder already
    /// indexed under this spelling is taken as is, so a pull's usual
    /// actions don't search the index.
    private static func caseClash(for path: String, in index: [String: FileRecord], ancestorsOnly: Bool = false) -> Bool {
        let components = path.split(separator: "/")
        let count = ancestorsOnly ? components.count - 1 : components.count
        guard count > 0 else { return false }
        return (1...count).contains { length in
            let prefix = components.prefix(length).joined(separator: "/")
            if let record = index[prefix], !record.isDeleted, length < components.count { return false }
            return index.contains { entry in
                entry.key != prefix && !entry.value.isDeleted && entry.key.caseInsensitiveCompare(prefix) == .orderedSame
            }
        }
    }

    /// Whether `path` contains a control character. Some file APIs cut a
    /// path at a NUL and others don't, so one name could stand for two.
    private static func hasControlCharacters(_ path: String) -> Bool {
        path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }

    /// How far ahead of this Mac's clock a peer's timestamps may run.
    /// Anything later is a broken clock or a broken peer, and would win
    /// every conflict for years.
    static let maximumClockSkew: SyncTimestamp = 7 * 24 * 60 * 60 * 1000

    /// Whether `timestamp` is one a working Mac could have made by `now`.
    static func isPlausible(_ timestamp: SyncTimestamp, now: SyncTimestamp) -> Bool {
        timestamp >= 0 && timestamp <= now + maximumClockSkew
    }

    /// Whether a peer's `record` has a plausible version and size. Its
    /// modification time can be anything a file system allows, including
    /// before 1970.
    static func isPlausible(_ record: FileRecord, now: SyncTimestamp) -> Bool {
        isPlausible(record.version, now: now) && record.size >= 0
    }

    /// Whether `path` is `ancestor` or inside it.
    private static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    /// Whether every folder between `root` and `url` is a real folder or
    /// doesn't exist yet, and, with `includingTarget`, `url` itself — even
    /// when it's `root` — isn't a symbolic link. A link anywhere below the
    /// root would lead a write, a deletion, or a download outside the item.
    static func hasNoLinks(below root: URL, to url: URL, includingTarget: Bool) -> Bool {
        let rootURL = root.standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents else { return false }
        if components.count == rootComponents.count {
            return !includingTarget || !isSymbolicLink(rootURL)
        }
        var current = rootURL
        let last = includingTarget ? components.count : components.count - 1
        for index in rootComponents.count..<last {
            current = current.appending(path: components[index])
            if isSymbolicLink(current) { return false }
        }
        return true
    }

    /// Whether `url` is a symbolic link; false when nothing is there. The
    /// path is checked without a trailing slash, which would make `lstat`
    /// follow the link.
    private static func isSymbolicLink(_ url: URL) -> Bool {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// Whether the disk at `url` still holds what `record` says it does.
    private static func disk(at url: URL, matches record: FileRecord?) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard let record, !record.isDeleted else {
            return values == nil
        }
        guard let values else { return false }
        switch record.kind {
        case .directory:
            return values.isDirectory == true
        case .file:
            return values.isRegularFile == true
                && Int64(values.fileSize ?? -1) == record.size
                && values.contentModificationDate?.syncTimestamp == record.modified
        }
    }

    /// Sets `url`'s modification time to `modified` and returns the time the
    /// file system kept, with the file's size.
    private static func setModified(_ modified: SyncTimestamp, of url: URL) throws -> (modified: SyncTimestamp, size: Int64) {
        try FileManager.default.setAttributes([.modificationDate: Date(syncTimestamp: modified)], ofItemAtPath: url.path(percentEncoded: false))
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ((values.contentModificationDate ?? .now).syncTimestamp, Int64(values.fileSize ?? 0))
    }

    /// Whether the directory at `url` holds nothing but names that are never
    /// synced, such as `.DS_Store`.
    private static func isEffectivelyEmpty(_ url: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        return contents.allSatisfy(FileScanner.isIgnored)
    }

    /// Whether `error` means the peer is gone, or no longer accepts this
    /// Mac's token, which ends a pull, rather than one path failing.
    private static func isConnectionFailure(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let urlError = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut, .cancelled, .userAuthenticationRequired].contains(urlError.code)
    }

    /// Runs blocking file-system work on the engine's queue.
    private static func onIOQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Like ``onIOQueue(_:)`` for work that can't fail.
    private static func onIOQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }
}
