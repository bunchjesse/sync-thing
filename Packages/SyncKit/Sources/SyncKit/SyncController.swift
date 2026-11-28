import AppKit
@_exported import DeviceTunnel
import Foundation
import Observation
import os

/// Everything that names this build's sync network and where it keeps its
/// state, supplied by the app.
public struct SyncConfiguration: Sendable {
    /// The tunnel's Keychain names, protocol name, Bonjour type, and relay
    /// namespace. Debug and Release builds should differ, so they never
    /// sync with each other.
    public var remoteAccess: RemoteAccessConfiguration
    /// The name other Macs show for this one.
    public var deviceName: String
    /// Where the item list and indexes are kept.
    public var stateDirectory: URL
    /// Where portable paths point on this Mac.
    public var locations: SyncLocations

    /// Creates a configuration.
    public init(remoteAccess: RemoteAccessConfiguration, deviceName: String, stateDirectory: URL, locations: SyncLocations) {
        self.remoteAccess = remoteAccess
        self.deviceName = deviceName
        self.stateDirectory = stateDirectory
        self.locations = locations
    }
}

/// Runs syncing on this Mac and publishes its state to the UI.
///
/// Each Mac is both a host and a client. As a host it serves its items to
/// the account's other Macs through ``RemoteHostService``, which admits any
/// Mac signed in to the same Apple Account. As a client it keeps a
/// ``RemoteHostLink`` to every other Mac in the iCloud Keychain registry —
/// found over Bonjour or at its published addresses, and through a relay
/// when one is set — and pulls from it whenever it connects, when it says
/// it changed, and every ``pullInterval``. When this Mac's files change it
/// tells every connected Mac, which then pulls. The registry is read at
/// launch, on wake, every ``registryPollInterval``, and when a Mac it
/// doesn't list yet says it changed. Items that reached copies this Mac
/// already had wait for ``answerJoin(_:with:)``.
@MainActor
@Observable
public final class SyncController {
    /// Whether syncing is up.
    public enum Status: Equatable, Sendable {
        /// ``start()`` hasn't finished.
        case starting
        /// Syncing is up.
        case running
        /// Syncing can't run, for the given reason, such as a build that
        /// can't use the Keychain.
        case unavailable(String)
    }

    /// One synced folder or file, as the UI shows it.
    public struct ItemState: Identifiable, Hashable, Sendable {
        /// The item's portable path.
        public let id: String
        /// Whether it's a folder or a file.
        public let kind: SyncItem.Kind
        /// Where it lives on this Mac.
        public let url: URL
        /// Whether it's missing on this Mac, which pauses it.
        public let isMissing: Bool
        /// How many files it holds here.
        public let fileCount: Int
        /// Whether it waits for the user's ``JoinChoice`` before syncing.
        public let isAwaitingChoice: Bool

        /// Creates an item state.
        public init(id: String, kind: SyncItem.Kind, url: URL, isMissing: Bool, fileCount: Int, isAwaitingChoice: Bool = false) {
            self.id = id
            self.kind = kind
            self.url = url
            self.isMissing = isMissing
            self.fileCount = fileCount
            self.isAwaitingChoice = isAwaitingChoice
        }
    }

    /// One of the account's other Macs, as the UI shows it.
    public struct PeerState: Identifiable, Hashable, Sendable {
        /// How this Mac reaches it.
        public enum Connection: Hashable, Sendable {
            /// Dialing it.
            case connecting
            /// Connected, directly or through the relay.
            case connected(ConnectionPath)
            /// Not reachable right now, for the given reason. The link keeps
            /// retrying.
            case unreachable(String)
        }

        /// The Mac's endpoint ID.
        public let id: String
        /// The Mac's name.
        public var name: String
        /// How this Mac reaches it.
        public var connection: Connection
        /// Whether a pull from it is under way.
        public var isSyncing: Bool
        /// When the last pull that reached it finished.
        public var lastSynced: Date?
        /// Why the last pull failed, if it did.
        public var lastError: String?

        /// Whether this Mac has a connection to it, directly or through the
        /// relay.
        public var isConnected: Bool {
            if case .connected = connection { true } else { false }
        }

        /// Creates a peer state.
        public init(id: String, name: String, connection: Connection, isSyncing: Bool = false, lastSynced: Date? = nil, lastError: String? = nil) {
            self.id = id
            self.name = name
            self.connection = connection
            self.isSyncing = isSyncing
            self.lastSynced = lastSynced
            self.lastError = lastError
        }
    }

    /// Whether syncing is up.
    public private(set) var status: Status = .starting
    /// The synced items, sorted by path.
    public private(set) var items: [ItemState] = []
    /// The account's other Macs, sorted by name.
    public private(set) var peers: [PeerState] = []
    /// The relay this Mac registers with, as `host:port`, or nil for none.
    public private(set) var relayAddress: String?
    /// Where this Mac's registration with its relay stands.
    public private(set) var relayStatus: RemoteNode.RelayStatus = .off
    /// The last error adding an item, for the UI to show once.
    public var lastAddError: String?
    /// Items whose copies here differ from the other Macs', waiting for
    /// ``answerJoin(_:)``.
    public private(set) var joinQuestion: JoinQuestion?
    /// The synced files that changed most recently, newest first, at most
    /// ``recentFileLimit``.
    public private(set) var recentFiles: [RecentFile] = []

    /// Whether any pull is under way.
    public var isSyncing: Bool { peers.contains(where: \.isSyncing) }

    /// How many files ``recentFiles`` lists.
    static let recentFileLimit = 10

    /// How often every connected Mac is pulled from, in case a change
    /// announcement was missed.
    static let pullInterval: Duration = .seconds(60)
    /// How often every item is rescanned, in case FSEvents missed a change.
    static let rescanInterval: Duration = .seconds(600)
    /// How often the registry is re-read for Macs that joined or left. It's
    /// also read at launch, on wake, and when a Mac it doesn't list yet says
    /// it changed.
    static let registryPollInterval: Duration = .seconds(15 * 60)
    /// The least time between registry reads that unknown Macs' change
    /// announcements cause.
    static let announcedRefreshInterval: Duration = .seconds(10)
    /// How long addresses must stay unchanged before they're published.
    static let addressSettleDelay: Duration = .seconds(3)
    /// How long changes gather before they're announced to peers.
    static let announceDelay: Duration = .milliseconds(500)
    /// How many hex digits of this Mac's endpoint ID name it in version
    /// vectors: 64 bits, unique among one account's Macs and short enough
    /// to repeat in every record. At most
    /// `VersionVector.maximumMacIDLength`.
    static let macIDLength = 16

    private static let log = Logger(subsystem: "dev.bunch.SyncKit", category: "controller")
    private static let relayAddressKey = "relayAddress"
    private static let listeningPortKey = "listeningPort"

    @ObservationIgnored private let configuration: SyncConfiguration?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var server: SyncServer?
    @ObservationIgnored private let tokens = SyncTokens()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var identity: DeviceIdentity?
    @ObservationIgnored private var node: RemoteNode?
    @ObservationIgnored private var registry: DeviceRegistry?
    @ObservationIgnored private var trustedHosts: TrustedHosts?
    @ObservationIgnored private var sessions: [String: PeerSession] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingAnnounce: Task<Void, Never>?
    @ObservationIgnored private var pendingAddressPublish: Task<Void, Never>?
    @ObservationIgnored private var lastPublish: Task<Void, Never>?
    @ObservationIgnored private var lastAnnouncedRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var isRefreshingItems = false
    @ObservationIgnored private var needsItemsRefresh = false
    @ObservationIgnored private var isStarted = false

    /// Creates a controller for `configuration`. Call ``start()`` to begin
    /// syncing.
    public init(configuration: SyncConfiguration, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.defaults = defaults
        self.relayAddress = defaults.string(forKey: Self.defaultsKey(Self.relayAddressKey, for: configuration)).flatMap(RemoteNode.canonicalRelayAddress)
    }

    /// `key` for this build's sync network and instance, so Debug, Release,
    /// and side-by-side instances keep their own settings.
    private static func defaultsKey(_ key: String, for configuration: SyncConfiguration) -> String {
        let remote = configuration.remoteAccess
        return [remote.keychainServicePrefix, remote.localInstance, key].compactMap(\.self).joined(separator: ".")
    }

    private init(
        previewStatus: Status,
        items: [ItemState],
        peers: [PeerState],
        relayAddress: String?,
        relayStatus: RemoteNode.RelayStatus?,
        joinQuestion: JoinQuestion?
    ) {
        self.configuration = nil
        self.defaults = .standard
        self.status = previewStatus
        self.items = items
        self.peers = peers
        self.relayAddress = relayAddress
        self.relayStatus = relayStatus ?? (relayAddress == nil ? .off : .registered)
        self.joinQuestion = joinQuestion
    }

    /// A controller showing fixed state that never syncs, for previews.
    ///
    /// When `relayStatus` is nil, the relay shows as registered if
    /// `relayAddress` is set and off otherwise.
    public static func preview(
        status: Status = .running,
        items: [ItemState] = [],
        peers: [PeerState] = [],
        relayAddress: String? = nil,
        relayStatus: RemoteNode.RelayStatus? = nil,
        joinQuestion: JoinQuestion? = nil
    ) -> SyncController {
        SyncController(
            previewStatus: status,
            items: items,
            peers: peers,
            relayAddress: relayAddress,
            relayStatus: relayStatus,
            joinQuestion: joinQuestion
        )
    }

    // MARK: - Lifecycle

    /// Starts syncing: loads this Mac's state and identity, starts the
    /// server peers pull from and the tunnel endpoint, and connects to the
    /// account's other Macs. Called once; when something fails, ``status``
    /// says why and nothing is left running.
    public func start() async {
        guard let configuration, !isStarted else { return }
        isStarted = true
        do {
            let remote = configuration.remoteAccess
            let store = SystemKeychainStore(accessGroup: remote.keychainAccessGroup)
            let identity = try await Self.offMain { try DeviceIdentity.loadOrCreate(store: store, configuration: remote) }
            self.identity = identity
            let engine = try SyncEngine(
                macID: String(identity.endpointID.prefix(Self.macIDLength)),
                locations: configuration.locations,
                stateDirectory: configuration.stateDirectory
            )
            self.engine = engine
            await engine.observe { [weak self] event in
                Task { @MainActor in self?.engineChanged(event) }
            }

            let server = SyncServer(engine: engine, tokens: tokens) { [weak self] endpointID in
                Task { @MainActor in await self?.peerChanged(endpointID) }
            }
            self.server = server
            try await server.start()

            let watcher = FileWatcher { [weak self] itemIDs in
                Task { @MainActor in await self?.rescan(itemIDs) }
            }
            self.watcher = watcher
            await refreshItems()

            let registry = DeviceRegistry(store: store, configuration: remote)
            self.registry = registry
            trustedHosts = TrustedHosts(store: store, configuration: remote)
            let portKey = Self.defaultsKey(Self.listeningPortKey, for: configuration)
            let storedPort = UInt16(exactly: defaults.integer(forKey: portKey)).flatMap { $0 == 0 ? nil : $0 }
            let node = try await RemoteNode.start(identity: identity, configuration: remote, acceptingDevicesIn: registry, preferredPort: storedPort)
            self.node = node
            node.setDialsThroughRelays(true)
            node.setRelay(relayAddress)
            observe(node)
            startHostService(on: node, registry: registry, approvals: DeviceApprovals(store: store, configuration: remote), deviceName: configuration.deviceName)

            status = .running
            Self.log.notice("Syncing as \(identity.endpointID.prefix(12), privacy: .public)")
            await publishThisMac(registry: registry)
            await refreshPeers()
            startTimers()
            await rescanAndAnnounce()
        } catch {
            Self.log.error("Syncing unavailable: \(error.localizedDescription, privacy: .public)")
            status = .unavailable(error.localizedDescription)
            tearDown()
        }
    }

    /// Stops everything ``start()`` started.
    private func tearDown() {
        tasks.forEach { $0.cancel() }
        tasks = []
        sessions.values.forEach { $0.stop() }
        sessions = [:]
        watcher?.stop()
        server?.stop()
        watcher = nil
        server = nil
        node = nil
        registry = nil
        trustedHosts = nil
        engine = nil
    }

    // MARK: - Actions

    /// Starts syncing each of `urls` on every Mac. Errors are reported
    /// through ``lastAddError``.
    public func add(_ urls: [URL]) async {
        guard let engine else { return }
        for url in urls {
            do {
                try await engine.addItem(at: url)
            } catch {
                lastAddError = error.localizedDescription
            }
        }
        await refreshItems()
    }

    /// Stops syncing `itemID` on every Mac. Its files stay put.
    public func remove(itemID: String) async {
        await engine?.removeItem(id: itemID)
        await refreshItems()
    }

    /// Pulls from every connected Mac now.
    public func syncNow() {
        for session in sessions.values {
            session.requestPull()
        }
    }

    /// Settles the items in `question` — the one the user answered — by
    /// `choice`, then syncs.
    public func answerJoin(_ question: JoinQuestion, with choice: JoinChoice) async {
        await engine?.answerJoin(choice, itemIDs: question.items.map(\.id))
        await refreshItems()
        syncNow()
    }

    /// Registers this Mac with the relay at `address` (`host` or `host:port`),
    /// or with none when it's empty. Returns false, changing nothing, when
    /// `address` isn't a valid relay address.
    @discardableResult
    public func setRelayAddress(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        let canonical: String?
        if trimmed.isEmpty {
            canonical = nil
        } else if let parsed = RemoteNode.canonicalRelayAddress(trimmed) {
            canonical = parsed
        } else {
            return false
        }
        guard canonical != relayAddress else { return true }
        relayAddress = canonical
        if let configuration {
            defaults.set(canonical, forKey: Self.defaultsKey(Self.relayAddressKey, for: configuration))
        }
        node?.setRelay(canonical)
        Task { await publishThisMac() }
        return true
    }

    // MARK: - Peers

    /// Re-reads the registry: links to Macs that joined, drops ones that
    /// left, and hands record changes to the links.
    private func refreshPeers() async {
        guard let identity, let node, let engine, let registry, let trustedHosts else { return }
        let hosts: [DeviceRecord]
        do {
            hosts = try await Self.offMain {
                let hosts = try registry.records().filter { $0.endpointID != identity.endpointID && $0.canHost && $0.platform == .macOS }
                try Self.trustAccountMacs(hosts, in: trustedHosts, revocations: registry.revocations())
                return hosts
            }
        } catch {
            Self.log.error("Couldn't read the device registry: \(error.localizedDescription, privacy: .public)")
            return
        }
        let ids = Set(hosts.map(\.endpointID))
        for (id, session) in sessions where !ids.contains(id) {
            session.stop()
            sessions[id] = nil
        }
        for record in hosts {
            if let session = sessions[record.endpointID] {
                session.update(record: record)
            } else {
                let session = PeerSession(record: record, node: node, trustedHosts: trustedHosts, engine: engine) { [weak self] in
                    self?.publishPeers()
                }
                sessions[record.endpointID] = session
                session.start()
            }
        }
        publishPeers()
    }

    /// Distrusts every revoked Mac for good, then trusts each of `hosts`
    /// this Mac hasn't decided about, since every Mac on the account is
    /// trusted. A Mac distrusted once stays distrusted.
    private nonisolated static func trustAccountMacs(_ hosts: [DeviceRecord], in trustedHosts: TrustedHosts, revocations: [DeviceRevocation]) throws {
        try trustedHosts.applyRevocations(revocations)
        for host in hosts where try trustedHosts.decision(for: host.endpointID) == nil {
            try trustedHosts.trust(host)
        }
    }

    private func publishPeers() {
        let states = sessions.values.map(\.state).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if states != peers {
            peers = states
        }
    }

    /// Pulls from `endpointID`, which said it changed. A Mac with no link
    /// is new, so the registry is read again — at most once per
    /// ``announcedRefreshInterval`` — which links to it and pulls.
    private func peerChanged(_ endpointID: String) async {
        if let session = sessions[endpointID] {
            session.requestPull()
            return
        }
        let now = ContinuousClock.now
        if let last = lastAnnouncedRefresh, now - last < Self.announcedRefreshInterval { return }
        lastAnnouncedRefresh = now
        await refreshPeers()
    }

    // MARK: - Changes

    private func engineChanged(_ event: SyncEngine.Event) {
        Task { await refreshItems() }
        switch event {
        case .availabilityChanged, .joinQuestionChanged: return
        case .itemsChanged, .filesChanged: announceSoon()
        }
    }

    /// Rescans the items FSEvents says changed.
    private func rescan(_ itemIDs: Set<String>) async {
        guard let engine else { return }
        for itemID in itemIDs {
            await engine.rescan(itemID: itemID)
        }
    }

    private func rescanAndAnnounce() async {
        guard let engine else { return }
        await engine.rescanAll()
        announceSoon()
    }

    /// Tells every connected Mac this one changed, once changes stop
    /// arriving for ``announceDelay``.
    private func announceSoon() {
        pendingAnnounce?.cancel()
        pendingAnnounce = Task { [weak self] in
            try? await Task.sleep(for: Self.announceDelay)
            guard !Task.isCancelled, let self else { return }
            for session in self.sessions.values {
                session.announceChange()
            }
        }
    }

    /// Reloads ``items`` from the engine and watches them. Calls made while
    /// one is under way fold into a single reload after it, so an older
    /// snapshot never lands after a newer one.
    private func refreshItems() async {
        guard !isRefreshingItems else {
            needsItemsRefresh = true
            return
        }
        isRefreshingItems = true
        defer { isRefreshingItems = false }
        repeat {
            needsItemsRefresh = false
            guard let engine else { return }
            var states: [ItemState] = []
            for item in await engine.activeItems() {
                states.append(ItemState(
                    id: item.id,
                    kind: item.kind,
                    url: engine.url(for: item),
                    isMissing: await engine.isMissing(item.id),
                    fileCount: await engine.fileCount(item.id),
                    isAwaitingChoice: await engine.isAwaitingChoice(item.id)
                ))
            }
            if states != items {
                items = states
            }
            let question = await engine.joinQuestion()
            if question != joinQuestion {
                joinQuestion = question
            }
            let recent = await engine.recentFiles(limit: Self.recentFileLimit)
            if recent != recentFiles {
                recentFiles = recent
            }
            watcher?.watch(states.map { (id: $0.id, url: $0.url, isFile: $0.kind == .file) })
        } while needsItemsRefresh
    }

    // MARK: - Tunnel

    private func startHostService(on node: RemoteNode, registry: DeviceRegistry, approvals: DeviceApprovals, deviceName: String) {
        let tokens = tokens
        let server = server
        let service = RemoteHostService(node: node, environment: RemoteHostService.Environment(
            registry: registry,
            approvals: approvals,
            hostName: { deviceName },
            localPort: { server?.port },
            token: { tokens.token(for: $0) },
            revokeToken: { tokens.revoke($0) },
            // Every Mac signed in to this Apple Account is trusted.
            requestApproval: { _ in .approved },
            isAcceptingConnections: { true },
            connectionsChanged: { _ in }
        ))
        tasks.append(Task { await service.run() })
    }

    private func observe(_ node: RemoteNode) {
        node.onAddressChange { [weak self] in
            Task { @MainActor in self?.addressChanged() }
        }
        node.onNetworkChange { [weak self] in
            Task { @MainActor in self?.sessions.values.forEach { $0.networkChanged() } }
        }
        node.onRoutesChange { [weak self] endpointIDs in
            Task { @MainActor in
                for id in endpointIDs {
                    self?.sessions[id]?.routesChanged()
                }
            }
        }
        node.onRelayStatusChange { [weak self] _ in
            Task { @MainActor in self?.relayStatus = self?.node?.relayStatus ?? .off }
        }
    }

    private func startTimers() {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.registryPollInterval)
                await self?.refreshPeers()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pullInterval)
                self?.syncNow()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.rescanInterval)
                await self?.rescanAndAnnounce()
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                guard let self else { return }
                Self.log.notice("Woke; reconnecting")
                self.node?.restartDiscovery()
                self.sessions.values.forEach { $0.reconnect() }
                await self.refreshPeers()
                await self.rescanAndAnnounce()
            }
        })
    }

    private func addressChanged() {
        pendingAddressPublish?.cancel()
        pendingAddressPublish = Task { [weak self] in
            try? await Task.sleep(for: Self.addressSettleDelay)
            guard !Task.isCancelled else { return }
            await self?.publishThisMac()
        }
    }

    /// Writes this Mac's registry record, after any write already under way.
    private func publishThisMac(registry: DeviceRegistry? = nil) async {
        guard let configuration, let identity, let node else { return }
        let registry = registry ?? DeviceRegistry(
            store: SystemKeychainStore(accessGroup: configuration.remoteAccess.keychainAccessGroup),
            configuration: configuration.remoteAccess
        )
        if let port = node.listeningPort {
            defaults.set(Int(port), forKey: Self.defaultsKey(Self.listeningPortKey, for: configuration))
        }
        let record = DeviceRecord(
            endpointID: identity.endpointID,
            gateKey: identity.gateKey,
            name: configuration.deviceName,
            platform: .macOS,
            canHost: true,
            directAddresses: node.address(),
            relayAddress: relayAddress
        )
        let previous = lastPublish
        let publish = Task {
            await previous?.value
            do {
                try await Self.offMain { try registry.publish(record) }
            } catch {
                Self.log.error("Couldn't publish this Mac: \(error.localizedDescription, privacy: .public)")
            }
        }
        lastPublish = publish
        await publish.value
    }

    /// Runs blocking Keychain work off the main actor and the cooperative
    /// thread pool.
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// This Mac's link to one other Mac, and the pulls made through it.
///
/// Pulls never overlap: requests that arrive during one coalesce into a
/// single pull after it.
@MainActor
final class PeerSession {
    /// What the UI shows for the Mac.
    private(set) var state: SyncController.PeerState

    private var link: RemoteHostLink!
    private let engine: SyncEngine
    private let onChange: @MainActor () -> Void
    private var peer: HTTPSyncPeer?
    private let pulls: AsyncStream<Void>
    private let pullRequests: AsyncStream<Void>.Continuation
    private var loop: Task<Void, Never>?

    init(record: DeviceRecord, node: RemoteNode, trustedHosts: TrustedHosts, engine: SyncEngine, onChange: @escaping @MainActor () -> Void) {
        self.engine = engine
        self.onChange = onChange
        self.state = .init(id: record.endpointID, name: record.name, connection: .connecting)
        (pulls, pullRequests) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.link = RemoteHostLink(node: node, host: record, trustedHosts: trustedHosts) { [weak self] linkState in
            await self?.linkChanged(linkState)
        }
    }

    /// Starts connecting, and pulls each time a pull is requested.
    func start() {
        Task { await link.start() }
        loop = Task { [weak self] in
            guard let pulls = self?.pulls else { return }
            for await _ in pulls {
                await self?.pull()
            }
        }
    }

    /// Disconnects and stops pulling.
    func stop() {
        loop?.cancel()
        pullRequests.finish()
        Task { await link.stop() }
    }

    /// Hands the link the Mac's latest registry record.
    func update(record: DeviceRecord) {
        link.update(host: record)
        if state.name != record.name {
            state.name = record.name
            onChange()
        }
    }

    /// Pulls from the Mac soon. Ignored while it isn't connected, since
    /// connecting pulls anyway.
    func requestPull() {
        guard peer != nil else { return }
        pullRequests.yield()
    }

    /// Tells the Mac this one changed, if it's connected. A lost
    /// announcement is made up for by the Mac's next periodic pull.
    func announceChange() {
        guard let peer else { return }
        let name = state.name
        Task {
            do {
                try await peer.announceChange()
            } catch {
                Self.log.info("Couldn't tell \(name, privacy: .private) about a change: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Passes a network change on to the link.
    func networkChanged() { Task { await link.networkChanged() } }
    /// Passes a change to the Mac's routes on to the link.
    func routesChanged() { Task { await link.routesChanged() } }
    /// Drops the connection and dials again.
    func reconnect() { Task { await link.reconnect() } }

    private static let log = Logger(subsystem: "dev.bunch.SyncKit", category: "peer")

    private func linkChanged(_ linkState: RemoteHostLink.State) {
        switch linkState {
        case .connected(let port, let token, let path):
            peer = HTTPSyncPeer(id: state.id, port: port, token: token)
            state.connection = .connected(path)
            pullRequests.yield()
        case .connecting, .awaitingApproval:
            peer = nil
            state.connection = .connecting
        case .notRecognized:
            peer = nil
            state.connection = .unreachable("Waiting for iCloud Keychain to reach \(state.name).")
        case .localNetworkDenied:
            peer = nil
            state.connection = .unreachable("Local Network access is off for SyncThing.")
        case .denied:
            peer = nil
            state.connection = .unreachable("\(state.name) refused this Mac.")
        case .untrustedHost:
            peer = nil
            state.connection = .unreachable("This Mac no longer trusts \(state.name).")
        case .unavailable(let reason), .unreachable(let reason):
            peer = nil
            state.connection = .unreachable(reason)
        }
        onChange()
    }

    private func pull() async {
        guard let peer else { return }
        state.isSyncing = true
        onChange()
        do {
            let report = try await engine.pull(from: peer)
            state.lastSynced = .now
            state.lastError = report.failed == 0 ? nil : "\(report.failed) \(report.failed == 1 ? "file" : "files") couldn’t sync; retrying."
        } catch is CancellationError {
        } catch {
            Self.log.info("Couldn't pull from \(self.state.name, privacy: .private): \(error.localizedDescription, privacy: .public)")
            state.lastError = error.localizedDescription
        }
        state.isSyncing = false
        onChange()
    }
}
