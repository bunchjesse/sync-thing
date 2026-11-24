import CoreServices
import Foundation
import Synchronization

/// Reports which synced items changed on disk, using FSEvents.
///
/// The watcher follows the folders that hold the items — an item's own
/// folder, or the folder a single-file item lives in — and maps each event
/// back to the items it touches. FSEvents coalesces bursts of changes for
/// ``latency``, so a save that writes several files becomes one rescan.
final class FileWatcher: Sendable {
    /// How long FSEvents gathers changes before reporting them.
    static let latency: CFTimeInterval = 1.0

    /// What a stream's callback needs. The stream retains it, so a callback
    /// still in flight when the stream is torn down never touches freed
    /// memory.
    private final class Target: Sendable {
        let roots: [String: Root]
        let onChange: @Sendable (Set<String>) -> Void

        init(roots: [String: Root], onChange: @escaping @Sendable (Set<String>) -> Void) {
            self.roots = roots
            self.onChange = onChange
        }
    }

    /// An item's path as FSEvents reports it, and whether it's a single file.
    private struct Root: Equatable, Sendable {
        let path: String
        let isFile: Bool
    }

    /// The running stream and the roots it watches. Only the reference to
    /// the stream is kept under the lock; the stream itself is safe to use
    /// from any thread.
    private struct State: @unchecked Sendable {
        var stream: FSEventStreamRef?
        var roots: [String: Root] = [:]
    }

    private let onChange: @Sendable (Set<String>) -> Void
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "dev.bunch.SyncKit.watcher")

    /// Creates a watcher that calls `onChange` with the IDs of the items
    /// whose files changed.
    init(onChange: @escaping @Sendable (Set<String>) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stopStream()
    }

    /// Watches `items` instead of whatever was watched before.
    func watch(_ items: [(id: String, url: URL, isFile: Bool)]) {
        let roots = Dictionary(items.map { ($0.id, Root(path: Self.realPath($0.url), isFile: $0.isFile)) }, uniquingKeysWith: { first, _ in first })
        let unchanged = state.withLock { $0.stream != nil && $0.roots == roots }
        guard !unchanged else { return }
        stopStream()
        let watched = Set(roots.values.map { $0.isFile ? ($0.path as NSString).deletingLastPathComponent : $0.path })
        guard !watched.isEmpty else {
            state.withLock { $0.roots = roots }
            return
        }

        let target = Unmanaged.passRetained(Target(roots: roots, onChange: onChange))
        var context = FSEventStreamContext(
            version: 0,
            info: target.toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Target>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Target>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let target = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            FileWatcher.report(changed.prefix(count), to: target)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        let stream = FSEventStreamCreate(nil, callback, &context, Array(watched) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        target.release()
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        state.withLock { state in
            state.stream = stream
            state.roots = roots
        }
    }

    /// Stops watching.
    func stop() {
        stopStream()
        state.withLock { $0.roots = [:] }
    }

    private func stopStream() {
        guard let stream = state.withLock({ state -> FSEventStreamRef? in
            defer { state.stream = nil }
            return state.stream
        }) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// `url`'s path as FSEvents reports it, with every symbolic link —
    /// including `/tmp` and `/var` — resolved. A path that doesn't exist yet
    /// resolves as far as its existing parent does.
    static func realPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path(percentEncoded: false) != path else { return path }
        return (realPath(parent) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    /// Maps changed `paths` to the items in `target` they belong to.
    private static func report(_ paths: some Sequence<String>, to target: Target) {
        var changed: Set<String> = []
        for path in paths {
            for (id, root) in target.roots {
                let touches = root.isFile
                    ? path == root.path || (root.path as NSString).deletingLastPathComponent == path
                    : path == root.path || path.hasPrefix(root.path + "/")
                if touches {
                    changed.insert(id)
                }
            }
        }
        if !changed.isEmpty {
            target.onChange(changed)
        }
    }
}
