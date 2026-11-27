import AppKit
import ServiceManagement
import SwiftUI
import SyncKit

/// SyncThing's window: what's synced, the other Macs, and the settings.
struct SyncWindow: View {
    /// The identifier of the window's scene, for opening it.
    static let id = "main"

    /// The controller whose state the window shows.
    let controller: SyncController
    /// The updater whose settings the window shows.
    let updater: Updater

    var body: some View {
        Form {
            if case .unavailable(let reason) = controller.status {
                Section {
                    Label {
                        Text("SyncThing Can’t Sync")
                        Text(reason)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if let question = controller.joinQuestion {
                JoinSection(question: question) { choice in
                    Task { await controller.answerJoin(question, with: choice) }
                }
            }
            ItemsSection(controller: controller)
            PeersSection(controller: controller)
            OptionsSection(controller: controller)
            UpdatesSection(updater: updater)
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 400)
        .alert(
            "Couldn’t Sync That",
            isPresented: Binding(get: { controller.lastAddError != nil }, set: { if !$0 { controller.lastAddError = nil } }),
            presenting: controller.lastAddError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}

/// Asks which copies win when items from the other Macs reached copies this
/// Mac already had: one answer for every item, confirmed before anything
/// moves to the Trash.
private struct JoinSection: View {
    /// The items the answer settles.
    let question: JoinQuestion
    /// Called with the confirmed answer.
    let answer: (JoinChoice) -> Void
    /// The answer waiting for confirmation.
    @State private var pending: JoinChoice?

    var body: some View {
        Section {
            Text("These were already on this Mac and differ from your other Macs. Choose which copies to keep; the others go to the Trash.")
                .foregroundStyle(.secondary)
            ForEach(question.items) { item in
                LabeledContent {
                    Text("\(item.differingFiles.formatted()) \(item.differingFiles == 1 ? "file differs" : "files differ")")
                } label: {
                    Text((item.id as NSString).lastPathComponent)
                    Text(item.id)
                }
            }
            HStack {
                Spacer()
                Button("Keep Other Macs’ Copies") { pending = .useOtherMacs }
                Button("Keep This Mac’s Copies") { pending = .useThisMac }
            }
        } header: {
            Label("Choose Which Copies to Keep", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
        }
        .confirmationDialog(
            pending == .useThisMac ? "Replace the files on your other Macs?" : "Replace the files on this Mac?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { choice in
            Button(choice == .useThisMac ? "Keep This Mac’s Copies" : "Keep Other Macs’ Copies", role: .destructive) {
                answer(choice)
            }
        } message: { choice in
            Text(choice == .useThisMac
                ? "Your other Macs’ files that differ, or that this Mac doesn’t have, go to their Trash."
                : "This Mac’s files that differ, or that your other Macs don’t have, go to the Trash.")
        }
    }
}

/// The synced folders and files, and the button that adds more.
private struct ItemsSection: View {
    let controller: SyncController

    var body: some View {
        Section("Folders and Files") {
            if controller.items.isEmpty {
                Text("Nothing yet. Anything you add here syncs to all your Macs.")
                    .foregroundStyle(.secondary)
            } else {
                let asked = Set(controller.joinQuestion?.items.map(\.id) ?? [])
                ForEach(controller.items) { item in
                    ItemRow(item: item, isAsked: asked.contains(item.id)) {
                        Task { await controller.remove(itemID: item.id) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Add Folder or File…", systemImage: "plus", action: chooseItems)
                    .disabled(controller.status != .running)
            }
        }
    }

    private func chooseItems() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = "Sync"
        panel.message = "Choose folders or files to keep the same on all your Macs."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await controller.add(urls) }
    }
}

/// One synced folder or file.
private struct ItemRow: View {
    let item: SyncController.ItemState
    /// Whether the item is in the window's join question, rather than held
    /// while its copies are still being compared.
    let isAsked: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind == .folder ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text(item.id)
                        .truncationMode(.middle)
                    if let state {
                        Text(" · \(state)")
                            .foregroundStyle(item.isMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for \(item.url.lastPathComponent)")
        }
        .contextMenu { actions }
    }

    /// The row's actions, in both its menu and its context menu.
    @ViewBuilder private var actions: some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        .disabled(item.isMissing)
        Divider()
        Button("Stop Syncing", role: .destructive, action: remove)
    }

    /// What follows the path: why the item is paused or held, or how many
    /// files a folder holds.
    private var state: String? {
        if item.isMissing {
            return "Not on this Mac, paused"
        }
        if item.isAwaitingChoice {
            return isAsked ? "Waiting for your choice" : "Comparing with your other Macs…"
        }
        guard item.kind == .folder else { return nil }
        return "\(item.fileCount.formatted()) \(item.fileCount == 1 ? "file" : "files")"
    }
}

/// The account's other Macs, how each is reached, and the button that
/// pulls from them now.
private struct PeersSection: View {
    let controller: SyncController

    var body: some View {
        Section("Other Macs") {
            if controller.peers.isEmpty {
                Text("Open SyncThing on another Mac signed in to the same Apple Account.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.peers) { peer in
                    PeerRow(peer: peer)
                }
                HStack {
                    Spacer()
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath", action: controller.syncNow)
                        .disabled(!controller.peers.contains(where: \.isConnected))
                        .help("Pull changes from your other Macs now")
                }
            }
        }
    }
}

/// One of the account's other Macs.
private struct PeerRow: View {
    let peer: SyncController.PeerState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if peer.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch peer.connection {
        case .connected: peer.lastError == nil ? .green : .orange
        case .connecting: .yellow
        case .unreachable: .secondary
        }
    }

    private var detail: String {
        switch peer.connection {
        case .connecting:
            return "Connecting…"
        case .unreachable(let reason):
            return reason
        case .connected(let path):
            let route = path == .relay ? "Through relay" : "Local network"
            if let error = peer.lastError {
                return "\(route) · \(error)"
            }
            if let lastSynced = peer.lastSynced {
                return "\(route) · Synced \(lastSynced.formatted(.relative(presentation: .named)))"
            }
            return route
        }
    }
}

/// Open at Login and the relay.
private struct OptionsSection: View {
    let controller: SyncController
    @State private var relay = ""
    @State private var relayIsInvalid = false
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @FocusState private var relayIsFocused: Bool

    var body: some View {
        Section("Options") {
            Toggle("Open at Login", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Relay", text: $relay, prompt: Text("None"))
                    .focused($relayIsFocused)
                    .onSubmit(applyRelay)
                    .onChange(of: relayIsFocused) { _, isFocused in
                        if !isFocused { applyRelay() }
                    }
                Text(relayCaption)
                    .font(.caption)
                    .foregroundStyle(relayCaptionStyle)
            }
        }
        .onAppear { relay = controller.relayAddress ?? "" }
    }

    /// The line under the relay field: why the entry was refused, how the
    /// relay is doing, or what a relay is for when none is set.
    private var relayCaption: String {
        if relayIsInvalid {
            return "Enter a host name, or host:port."
        }
        guard controller.relayAddress != nil else {
            return "Optional. A relay server lets your Macs reach each other from different networks."
        }
        return switch controller.relayStatus {
        case .off: "Relay off"
        case .connecting: "Connecting to the relay…"
        case .registered: "Connected to the relay"
        case .unavailable(let reason): "Can’t reach the relay: \(reason)"
        }
    }

    /// Red for a refused entry, orange while the relay can't be reached.
    private var relayCaptionStyle: Color {
        if relayIsInvalid {
            return .red
        }
        if controller.relayAddress != nil, case .unavailable = controller.relayStatus {
            return .orange
        }
        return .secondary
    }

    /// Saves the relay field when it differs from the saved relay, so
    /// leaving the field unchanged doesn't reconnect.
    private func applyRelay() {
        guard relay != (controller.relayAddress ?? "") else {
            relayIsInvalid = false
            return
        }
        relayIsInvalid = !controller.setRelayAddress(relay)
        if !relayIsInvalid {
            relay = controller.relayAddress ?? ""
        }
    }

    /// Registers or unregisters the app as a login item, then shows what
    /// macOS actually did: registering can need approval in System Settings.
    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Whether and when SyncThing updates itself, and the version running.
private struct UpdatesSection: View {
    let updater: Updater

    var body: some View {
        @Bindable var updater = updater
        Section("Updates") {
            if Updater.isEnabled {
                Toggle("Check for Updates Automatically", isOn: $updater.automaticallyChecksForUpdates)
            }
            LabeledContent {
                if Updater.isEnabled {
                    Button("Check Now", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                }
            } label: {
                Text("SyncThing \(Self.version)")
                Text(Updater.isEnabled ? "Updates come from github.com/bunchjesse/sync-thing." : "Debug builds don’t update themselves.")
            }
        }
    }

    /// The running version and build, such as "0.1 (2)".
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Sample state for previews.
private enum PreviewData {
    static let items: [SyncController.ItemState] = [
        SyncController.ItemState(id: "~/Documents/Notes", kind: .folder, url: URL(filePath: "/Users/me/Documents/Notes"), isMissing: false, fileCount: 248),
        SyncController.ItemState(id: "~/.zshrc", kind: .file, url: URL(filePath: "/Users/me/.zshrc"), isMissing: false, fileCount: 1),
        SyncController.ItemState(id: "/Volumes/Photos/Library", kind: .folder, url: URL(filePath: "/Volumes/Photos/Library"), isMissing: true, fileCount: 0),
    ]

    static let peers: [SyncController.PeerState] = [
        SyncController.PeerState(id: "a", name: "Studio", connection: .connected(.direct), lastSynced: Date.now.addingTimeInterval(-90)),
        SyncController.PeerState(id: "b", name: "MacBook Air", connection: .connected(.relay), isSyncing: true),
        SyncController.PeerState(id: "c", name: "Mac mini", connection: .unreachable("No route to the Mac.")),
    ]
}

#Preview("Syncing") {
    SyncWindow(controller: .preview(items: PreviewData.items, peers: PreviewData.peers, relayAddress: "relay.bunch.dev:3340"), updater: Updater())
}

#Preview("Empty") {
    SyncWindow(controller: .preview(), updater: Updater())
}

#Preview("Joining") {
    SyncWindow(controller: .preview(
        items: [
            SyncController.ItemState(id: "~/Documents/Notes", kind: .folder, url: URL(filePath: "/Users/me/Documents/Notes"), isMissing: false, fileCount: 240, isAwaitingChoice: true),
            SyncController.ItemState(id: "~/.zshrc", kind: .file, url: URL(filePath: "/Users/me/.zshrc"), isMissing: false, fileCount: 1, isAwaitingChoice: true),
            SyncController.ItemState(id: "~/Projects/Scripts", kind: .folder, url: URL(filePath: "/Users/me/Projects/Scripts"), isMissing: false, fileCount: 18, isAwaitingChoice: true),
        ],
        peers: PreviewData.peers,
        joinQuestion: JoinQuestion(items: [
            JoinQuestion.Item(id: "~/.zshrc", differingFiles: 1),
            JoinQuestion.Item(id: "~/Documents/Notes", differingFiles: 12),
        ])
    ), updater: Updater())
}

#Preview("Problems") {
    SyncWindow(controller: .preview(
        items: PreviewData.items,
        peers: [
            SyncController.PeerState(id: "a", name: "Studio", connection: .connected(.direct), lastSynced: .now, lastError: "3 files couldn’t sync; retrying."),
            SyncController.PeerState(id: "b", name: "MacBook Air", connection: .connecting),
            SyncController.PeerState(id: "c", name: "Mac mini", connection: .unreachable("Local Network access is off for SyncThing.")),
        ],
        relayAddress: "relay.bunch.dev:3340",
        relayStatus: .unavailable(reason: "The connection timed out.")
    ), updater: Updater())
}

#Preview("Unavailable") {
    SyncWindow(controller: .preview(status: .unavailable("This build can’t use the Keychain.")), updater: Updater())
}
