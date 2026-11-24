import AppKit
import ServiceManagement
import SwiftUI
import SyncKit

/// The window the menu bar icon opens: what's synced, the other Macs, and
/// a few settings.
struct SyncMenu: View {
    /// The controller whose state the menu shows.
    let controller: SyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .unavailable(let reason) = controller.status {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            ItemsSection(controller: controller)
            Divider()
            PeersSection(peers: controller.peers)
            Divider()
            SettingsSection(controller: controller)
        }
        .padding(14)
        .frame(width: 340)
        .alert(
            "Couldn't Sync That",
            isPresented: Binding(get: { controller.lastAddError != nil }, set: { if !$0 { controller.lastAddError = nil } }),
            presenting: controller.lastAddError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}

/// The synced folders and files, and the button that adds more.
private struct ItemsSection: View {
    let controller: SyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Syncing")
                .font(.headline)
            if controller.items.isEmpty {
                Text("Nothing yet. Anything you add here syncs to all your Macs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(controller.items) { item in
                    ItemRow(item: item) {
                        Task { await controller.remove(itemID: item.id) }
                    }
                }
            }
            Button("Add Folder or File…", systemImage: "plus") {
                chooseItems()
            }
            .disabled(controller.status != .running)
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
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await controller.add(urls) }
    }
}

/// One synced folder or file.
private struct ItemRow: View {
    let item: SyncController.ItemState
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind == .folder ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(item.isMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                .disabled(item.isMissing)
                Divider()
                Button("Stop Syncing", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for \(item.url.lastPathComponent)")
        }
    }

    private var detail: String {
        if item.isMissing {
            return "Not on this Mac — paused"
        }
        guard item.kind == .folder else { return item.id }
        return "\(item.id) · \(item.fileCount.formatted()) \(item.fileCount == 1 ? "file" : "files")"
    }
}

/// The account's other Macs and how each is reached.
private struct PeersSection: View {
    let peers: [SyncController.PeerState]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Macs")
                .font(.headline)
            if peers.isEmpty {
                Text("Open SyncThing on another Mac signed in to the same Apple Account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(peers) { peer in
                    PeerRow(peer: peer)
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

/// The relay, Open at Login, Sync Now, and Quit.
private struct SettingsSection: View {
    let controller: SyncController
    @State private var relay = ""
    @State private var relayIsInvalid = false
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Relay") {
                TextField("None", text: $relay, prompt: Text("relay.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyRelay)
                    .help("Optional. Reaches Macs on other networks through a rendezvous relay.")
            }
            if relayIsInvalid {
                Text("That isn't a host or host:port.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if controller.relayAddress != nil {
                Text(relayStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Open at Login", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
            HStack {
                Button("Sync Now") { controller.syncNow() }
                    .disabled(controller.peers.isEmpty)
                Spacer()
                Button("Quit SyncThing") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .onAppear { relay = controller.relayAddress ?? "" }
    }

    private var relayStatus: String {
        switch controller.relayStatus {
        case .off: "Relay off"
        case .connecting: "Connecting to relay…"
        case .registered: "Registered with relay"
        case .unavailable(let reason): "Relay unavailable: \(reason)"
        }
    }

    private func applyRelay() {
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
    SyncMenu(controller: .preview(items: PreviewData.items, peers: PreviewData.peers, relayAddress: "relay.bunch.dev:3340"))
}

#Preview("Empty") {
    SyncMenu(controller: .preview(items: [], peers: []))
}
